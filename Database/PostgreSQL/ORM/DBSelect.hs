{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE RecordWildCards #-}

module Database.PostgreSQL.ORM.DBSelect (
    -- * The DBSelect structure
    DBSelect(..), FromClause(..)
    -- * Executing DBSelects
  , dbSelectParams, dbSelect
  , Cursor(..), curSelect, curNext
  , dbFold, dbFoldM, dbFoldM_
  , dbCollect
  , renderDBSelect, buildDBSelect
    -- * Creating DBSelects
  , emptyDBSelect, expressionDBSelect
  , modelDBSelect
  , dbJoin, dbJoinModels
  , dbProject, dbProject'
  , dbNest, dbChain
    -- * Altering DBSelects
  , addWhere_, addWhere, setOrderBy, setLimit, setOffset, addExpression
  ) where

import Control.Monad.IO.Class
import Blaze.ByteString.Builder
import Blaze.ByteString.Builder.Char.Utf8 (fromChar)
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import Data.Functor
import Data.Monoid
import Data.String
import Data.IORef
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.Internal
import Database.PostgreSQL.Simple.Types
import GHC.Generics

import Database.PostgreSQL.Escape
import Database.PostgreSQL.ORM.Model

-- | As it's name would suggest, a @FromClause@ is the part of a query
-- between the @FROM@ keyword and the @WHERE@ keyword.  It can consist
-- of simple table names, @JOIN@ operations, and parenthesized
-- subqueries.
--
-- From clauses are represented in a more structured way than the
-- other fields so as to allow the possibility of collapsing join
-- relations.  For instance, given a @'DBSelect' (A :. B)@ and a
-- @'DBSelect' (B :. C)@, it is desirable to be able to generate a
-- @'DBSelect' (A :. B :. C)@ in which each pair of terms involving
-- @B@ in the three-way relation is constrained according to the
-- original two queries.  This functionality is provided by 'dbNest'
-- and 'dbChain', but it requires the ability to locate and replace
-- the instance of type @B@ in one 'DBSelect' with the @FromClause@ of
-- the other 'DBSelect'.
--
-- The 'fcCanonical' field is a canonical name of each type, which by
-- convention is the quoted and fully-qualified table name.  Comparing
-- 'fcCanonical' is somewhat of a hack, and happens entirely at
-- runtime.  It would be nicer to do this at compile time, but doing
-- so would require language extensions such as @GADTs@ of
-- @FunctionalDependencies@.
data FromClause = FromModel {
    fcVerbatim :: !Query -- ^ Verbatim SQL for a table, table @AS@
                         -- alias, or parenthesized subquery.
  , fcCanonical :: !S.ByteString
    -- ^ Canonical name of the table or join relation represented by
    -- this term.  For @JOIN@ terms, this is always the @CROSS JOIN@
    -- of the canonical names of 'fcLeft' and 'fcRight'.  This means
    -- one can locate a join given only it's type (e.g., the canonical
    -- name for @A :. B@ is always @\"a CROSS JOIN b\"@), but it does
    -- mean you have to be careful not accidentally to merge two
    -- different joins on the same types.  For this reason it may be
    -- safest always to have type @b@ be a single table in 'dbNest'
    -- and 'dbChain'.
  }
  | FromJoin {
    fcLeft :: !FromClause
  , fcJoinOp :: !Query -- ^ Usually @\"JOIN\"@
  , fcRight :: !FromClause
  , fcOnClause :: !Query -- ^ @ON@ or @USING@ clause (or empty)
  , fcCanonical :: !S.ByteString
  }
  deriving Show

nullFrom :: FromClause -> Bool
nullFrom (FromModel q _) | qNull q = True
nullFrom _                         = False

-- | A deconstructed SQL select statement that allows easier
-- manipulation of individual terms.  Several functions are provided
-- to combine the 'selFields', 'selFrom', and 'selWhere' clauses of
-- muliple @DBSelect@ structures.  Other clauses may be discarded when
-- combining queries with join operations.  Hence it is advisable to
-- set the other clauses at the end (or, if you set these fields, to
-- collapse your 'DBSelect' structure into a subquery using
-- `dbProject'`).
data DBSelect a = DBSelect {
    selWith :: !Query
  , selSelectKeyword :: !Query
    -- ^ By default @\"SELECT\"@, but might usefully be set to
    -- something else such as @\"SELECT DISTINCT\"@ in some
    -- situations.
  , selFields :: Query
  , selFrom :: !FromClause
  , selWhereKeyword :: !Query
    -- ^ Empty by default, but set to @\"WHERE\"@ if any @WHERE@
    -- clauses are added to the 'selWhere' field.
  , selWhere :: !Query
  , selGroupBy :: !Query
  , selHaving :: !Query
    -- below here, should appear outside any union
  , selOrderBy :: !Query
  , selLimit :: !Query
  , selOffset :: !Query
  } deriving (Generic)

instance Show (DBSelect a) where
  show = S8.unpack . fromQuery . renderDBSelect

space :: Builder
space = fromChar ' '

qNull :: Query -> Bool
qNull = S.null . fromQuery

qBuilder :: Query -> Builder
qBuilder = fromByteString . fromQuery

toQuery :: Builder -> Query
toQuery = Query . toByteString

buildFromClause :: FromClause -> Builder
buildFromClause (FromModel q _) | qNull q = mempty
buildFromClause cl0 = fromByteString " FROM " <> go cl0
  where go (FromModel q _) = qBuilder q
        go (FromJoin left joinkw right onClause _) = mconcat [
            fromChar '(', go left, space, qBuilder joinkw, space, go right
          , if qNull onClause then mempty else space <> qBuilder onClause
          , fromChar ')' ]

class GDBS f where
  gdbsDefault :: f p
  gdbsQuery :: f p -> Builder
instance GDBS (K1 i Query) where
  gdbsDefault = K1 (Query S.empty)
  gdbsQuery (K1 q) | qNull q = mempty
                   | otherwise = space <> qBuilder q
instance GDBS (K1 i FromClause) where
  gdbsDefault = K1 (FromModel "" "")
  gdbsQuery (K1 fc) = buildFromClause fc
instance (GDBS a, GDBS b) => GDBS (a :*: b) where
  gdbsDefault = gdbsDefault :*: gdbsDefault
  gdbsQuery (a :*: b) = gdbsQuery a <> gdbsQuery b
instance (GDBS f) => GDBS (M1 i c f) where
  gdbsDefault = M1 gdbsDefault
  gdbsQuery = gdbsQuery . unM1

-- | A 'DBSelect' structure with keyword @\"SELECT\"@ and everything
-- else empty.
emptyDBSelect :: DBSelect a
emptyDBSelect = (to gdbsDefault) { selSelectKeyword = fromString "SELECT" }

-- | A 'DBSelect' for one or more comma-separated expressions, rather
-- than for a table.  For example, to issue the query @\"SELECT
-- lastval()\"@:
--
-- > lastval :: DBSelect (Only DBKeyType)
-- > lastval = expressionDBSelect "lastval ()"
-- >
-- >   ...
-- >   [just_inserted_id] <- dbSelect conn lastval
--
-- On the other hand, for such a simple expression, you might as well
-- call 'query_' directly.
expressionDBSelect :: (Model r) => Query -> DBSelect r
expressionDBSelect q = emptyDBSelect { selFields = q }

-- | Create a 'Builder' for a rendered version of a 'DBSelect'.  This
-- can save one string copy if you want to embed one query inside
-- another as a subquery, as done by `dbProject'`, and thus need to
-- parenthesize it.  However, the function is probably not a useful
-- for end users.
buildDBSelect :: DBSelect a -> Builder
buildDBSelect dbs = gdbsQuery $ from dbs

-- | Turn a 'DBSelect' into a 'Query' suitable for the 'query' or
-- 'query_' functions.
renderDBSelect :: DBSelect a -> Query
renderDBSelect = Query . S.tail . toByteString . buildDBSelect
-- S.tail is because the rendering inserts an extra space at the beginning

catQueries :: Query -> Query -> Query -> Query
catQueries left delim right
  | qNull left  = right
  | qNull right = left
  | otherwise   = Query $ S.concat $ map fromQuery [left, delim, right]

-- | Add a where clause verbatim to a 'DBSelect'.  The clause must
-- /not/ contain the @WHERE@ keyword (which is added automatically by
-- @addWhere_@ if needed).  If the @DBSelect@ has existing @WHERE@
-- clauses, the new clause is appended with @AND@.  If the query
-- contains any @\'?\'@ characters, they will be rendered into the
-- query and matching parameters will later have to be filled in via a
-- call to 'dbSelectParams'.
addWhere_ :: Query -> DBSelect a -> DBSelect a
addWhere_ q dbs
  | qNull q = dbs
  | otherwise = dbs { selWhereKeyword = "WHERE"
                    , selWhere = catQueries (selWhere dbs) " AND " q }

-- | Add a where clause, and pre-render parameters directly into the
-- clause.  The argument @p@ must have exactly as many fields as there
-- are @\'?\'@ characters in the 'Query'.  Example:
--
-- > bars <- dbSelect c $ addWhere "bar_id = ?" (Only target_id) $
-- >                      (modelDBSelect :: DBSelect Bar)
addWhere :: (ToRow p) => Query -> p -> DBSelect a -> DBSelect a
addWhere q p dbs
  | qNull q = dbs
  | otherwise = dbs {
    selWhereKeyword = "WHERE"
  , selWhere = if qNull $ selWhere dbs
               then toQuery clause
               else toQuery $ qBuilder (selWhere dbs) <>
                    fromByteString " AND " <> clause
  }
  where clause = mconcat [fromChar '(', buildSql q p, fromChar ')']

-- | Set the @ORDER BY@ clause of a 'DBSelect'.  Example:
--
-- > dbSelect c $ setOrderBy "\"employeeName\" DESC NULLS FIRST" $
-- >                modelDBSelect
setOrderBy :: Query -> DBSelect a -> DBSelect a
setOrderBy (Query ob) dbs = dbs { selOrderBy = Query $ "ORDER BY " <> ob }

-- | Set the @LIMIT@ clause of a 'DBSelect'.
setLimit :: Int -> DBSelect a -> DBSelect a
setLimit i dbs = dbs { selLimit = fmtSql "LIMIT ?" (Only i) }

-- | Set the @OFFSET@ clause of a 'DBSelect'.
setOffset :: Int -> DBSelect a -> DBSelect a
setOffset i dbs = dbs { selOffset = fmtSql "OFFSET ?" (Only i) }

-- | Add one or more comma-separated expressions to 'selFields' that
-- produce column values without any corresponding relation in the
-- @FROM@ clause.  Type @r@ is the type into which the expression is
-- to be parsed.  Generally this will be an instance of 'FromRow' that
-- is a degenerate model (e.g., 'Only', or a tuple).
--
-- For example, to rank results by the field @value@ and compute the
-- fraction of overall value they contribute:
--
-- > r <- dbSelect c $ addExpression
-- >        "rank() OVER (ORDER BY value), value::float4/SUM(value) OVER ()"
-- >        modelDBSelect
-- >          :: IO [Bar :. (Int, Double)]
addExpression :: (Model r) => Query -> DBSelect a -> DBSelect (a :. r)
addExpression q dbs = dbs {
  selFields = if qNull $ selFields dbs then q
              else Query $ S.concat $ map fromQuery [selFields dbs, ", ", q]
  }

-- | A 'DBSelect' that returns all rows of a model.
modelDBSelect :: forall a. (Model a) => DBSelect a
modelDBSelect = r
  where mi = modelIdentifiers :: ModelIdentifiers a
        r = emptyDBSelect {
          selFields = Query $ S.intercalate ", " $ modelQColumns mi
          , selFrom = FromModel (Query $ modelQTable mi) (modelQTable mi)
          }

-- | Run a 'DBSelect' query on parameters.  The number of @\'?\'@
-- characters embedeed in various fields of the 'DBSelect' must
-- exactly match the number of fields in parameter type @p@.  Note the
-- order of arguments is such that the 'DBSelect' can be pre-rendered
-- and the parameters supplied later.  Hence, you should use this
-- version when the 'DBSelect' is static.  For dynamically modified
-- 'DBSelect' structures, you may prefer 'dbSelect'.
dbSelectParams :: (Model a, ToRow p) => DBSelect a -> Connection -> p -> IO [a]
{-# INLINE dbSelectParams #-}
dbSelectParams dbs = \c p -> map lookupRow <$> query c q p
  where {-# NOINLINE q #-}
        q = renderDBSelect dbs

-- | Run a 'DBSelect' query and return the resulting models.
dbSelect :: (Model a) => Connection -> DBSelect a -> IO [a]
{-# INLINE dbSelect #-}
dbSelect c dbs = map lookupRow <$> query_ c q
  where {-# NOINLINE q #-}
        q = renderDBSelect dbs

-- | Datatype that represents a connected cursor
data Cursor a = Cursor { curConn :: !Connection
                       , curName :: !Query
                       , curChunkSize :: !Query
                       , curCache :: IORef [a] }

-- | Create a 'Cursor' for the given 'DBSelect'
curSelect :: Model a => Connection -> DBSelect a -> IO (Cursor a)
curSelect c dbs = do
  name <- newTempName c
  execute_ c $
    mconcat [ "DECLARE ", name, " NO SCROLL CURSOR FOR ", q ]
  cacheRef <- newIORef []
  return $ Cursor c name "256" cacheRef
  where q = renderDBSelect dbs

-- | Fetch the next 'Model' for the underlying 'Cursor'. If the cache has
-- prefetched values, dbNext will return the head of the cache without querying
-- the database. Otherwise, it will prefetch the next 256 values, return the
-- first, and store the rest in the cache.
curNext :: Model a => Cursor a -> IO (Maybe a)
curNext Cursor{..} = do
  cache <- readIORef curCache
  case cache of
    x:xs -> do
      writeIORef curCache xs
      return $ Just x
    [] -> do
      res <- map lookupRow <$> query_ curConn (mconcat
              [ "FETCH FORWARD ", curChunkSize, " FROM ", curName])
      case res of
        [] -> return Nothing
        x:xs -> do
          writeIORef curCache xs
          return $ Just x

-- | Streams results of a 'DBSelect' and consumes them using a left-fold. Uses
-- default settings for 'Cursor' (batch size is 256 rows).
dbFold :: Model model
       => Connection -> (b -> model -> b) -> b -> DBSelect model -> IO b
dbFold c act initial dbs = do
  cur <- curSelect c dbs
  go cur initial
  where go cur accm = do
          mres <- curNext cur
          case mres of
            Nothing -> return accm
            Just res -> go cur (act accm res)

-- | Streams results of a 'DBSelect' and consumes them using a monadic
-- left-fold. Uses default settings for 'Cursor' (batch size is 256 rows).
dbFoldM :: (MonadIO m, Model model)
        => Connection -> (b -> model -> m b) -> b -> DBSelect model -> m b
dbFoldM c act initial dbs = do
  cur <- liftIO $ curSelect c dbs
  go cur initial
  where go cur accm = do
          mres <- liftIO $ curNext cur
          case mres of
            Nothing -> return accm
            Just res -> act accm res >>= go cur

-- | Streams results of a 'DBSelect' and consumes them using a monadic
-- left-fold. Uses default settings for 'Cursor' (batch size is 256 rows).
dbFoldM_ :: (MonadIO m, Model model)
         => Connection -> (model -> m ()) -> DBSelect model -> m ()
dbFoldM_ c act dbs = dbFoldM c (const act) () dbs

-- | Group the returned tuples by unique a's. Expects the query to return a's
-- in sequence -- all rows with the same value for a must be grouped together,
-- for example, by sorting the result on a's primary key column.
dbCollect :: (Model a, Model b)
           => Connection -> DBSelect (a :. b) -> IO [(a, [b])]
dbCollect c ab = dbFold c group [] ab
  where
    group :: (Model a, Model b) => [(a, [b])] -> (a :. b) -> [(a, [b])]
    group    []     (a :. b) = [(a, [b])]
    group ls@(l:_)  (a :. b) | primaryKey a /= primaryKey (fst l) = (a, [b]):ls
    group    (l:ls) (_ :. b) = (fst l, b:(snd l)):ls

-- | Create a join of the 'selFields', 'selFrom', and 'selWhere'
-- clauses of two 'DBSelect' queries.  Other fields are simply taken
-- from the second 'DBSelect', meaning fields such as 'selWith',
-- 'selGroupBy', and 'selOrderBy' in the in the first 'DBSelect' are
-- entirely ignored.
dbJoin :: forall a b.
          (Model a, Model b) =>
          DBSelect a      -- ^ First table
          -> Query        -- ^ Join keyword (@\"JOIN\"@, @\"LEFT JOIN\"@, etc.)
          -> DBSelect b   -- ^ Second table
          -> Query  -- ^ Predicate (if any) including @ON@ or @USING@ keyword
          -> DBSelect (a :. b)
dbJoin left joinOp right onClause = addWhere_ (selWhere left) right {
    selFields = Query $ S.concat [fromQuery $ selFields left, ", ",
                                  fromQuery $ selFields right]
  , selFrom = newfrom
  }
  where idab = modelIdentifiers :: ModelIdentifiers (a :. b)
        newfrom | nullFrom $ selFrom right = selFrom left
                | nullFrom $ selFrom left = selFrom right
                | otherwise = FromJoin (selFrom left) joinOp (selFrom right)
                              onClause (modelQTable idab)

-- | A version of 'dbJoin' that uses 'modelDBSelect' for the joined
-- tables.
dbJoinModels :: (Model a, Model b) =>
                Query           -- ^ Join keyword
                -> Query        -- ^ @ON@ or @USING@ predicate
                -> DBSelect (a :. b)
dbJoinModels kw on = dbJoin modelDBSelect kw modelDBSelect on

-- | Restrict the fields returned by a DBSelect to be those of a
-- single 'Model' @a@.  It only makes sense to do this if @a@ is part
-- of @something_containing_a@, but no static check is performed that
-- this is the case.  If you @dbProject@ a type that doesn't make
-- sense, you will get a runtime error from a failed database query.
dbProject :: forall a something_containing_a.
             (Model a) => DBSelect something_containing_a -> DBSelect a
{-# INLINE dbProject #-}
dbProject dbs = r
  where sela = modelDBSelect :: DBSelect a
        r = dbs { selFields = selFields sela }

-- | Like 'dbProject', but renders the entire input 'DBSelect' as a
-- subquery.  Hence, you can no longer mention fields of models other
-- than @a@ that might be involved in joins.  The two advantages of
-- this approach are 1) that you can once again join to tables that
-- were part of the original query without worrying about row aliases,
-- and 2) that all terms of the 'DBSelect' will be faithrully rendered
-- into the subquery (whereas otherwise they could get dropped by join
-- operations).  Generally you will still want to use 'dbProject', but
-- @dbProject'@ is available when needed.
dbProject' :: forall a something_containing_a.
              (Model a) => DBSelect something_containing_a -> DBSelect a
dbProject' dbs = r
  where sela = modelDBSelect :: DBSelect a
        ida = modelIdentifiers :: ModelIdentifiers a
        Just mq = modelQualifier ida
        q = toQuery $ fromChar '(' <>
            buildDBSelect dbs { selFields = selFields sela } <>
            fromByteString ") AS " <> fromByteString mq
        r = sela { selFrom = FromModel q $ modelQTable ida }

mergeFromClauses :: S.ByteString -> FromClause -> FromClause -> FromClause
mergeFromClauses canon left right =
  case go left of
    (fc, 1) -> fc
    (_, 0)  -> error $ "mergeFromClauses could not find " ++ show canon
    (_, _)  -> error $ "mergeFromClauses found duplicate " ++ show canon
  where go fc | fcCanonical fc == canon = (right, 1 :: Int)
        go (FromJoin l op r on ffc) =
          case (go l, go r) of
            ((lfc, ln), (rfc, rn)) -> (FromJoin lfc op rfc on ffc, ln + rn)
        go fc = (fc, 0)

-- | Nest two type-compatible @JOIN@ queries.  As with 'dbJoin',
-- fields of the first @JOIN@ (the @'DBSelect' (a :. b)@) other than
-- 'selFields', 'selFrom', and 'selWhere' are entirely ignored.
dbNest :: forall a b c. (Model a, Model b) =>
          DBSelect (a :. b) -> DBSelect (b :. c) -> DBSelect (a :. b :. c)
dbNest left right = addWhere_ (selWhere left) right {
    selFields = fields
  , selFrom = mergeFromClauses nameb (selFrom left) (selFrom right)
  }
  where nameb = modelQTable (modelIdentifiers :: ModelIdentifiers b)
        acols = modelQColumns (modelIdentifiers :: ModelIdentifiers a)
        colcomma c r = fromByteString c <> fromByteString ", " <> r
        fields = toQuery $ foldr colcomma (qBuilder $ selFields right)
                 acols

-- | Like 'dbNest', but projects away the middle type @b@.
dbChain :: (Model a, Model b, Model c) =>
           DBSelect (a :. b) -> DBSelect (b :. c) -> DBSelect (a :. c)
dbChain left right = dbProject $ dbNest left right
