{-# LANGUAGE DeriveDataTypeable, DefaultSignatures,
    FlexibleContexts, FlexibleInstances, TypeOperators, OverloadedStrings #-}

module Database.PostgreSQL.ORM.Model (
      -- * Data types for holding primary keys
    DBKeyType, DBKey(..), isNullKey
    , DBRef, DBURef, GDBRef(..), mkDBRef
      -- * The Model class
    , Model(..), ModelInfo(..), ModelQueries(..)
    , modelToInfo, gmodelToInfo, modelToQueries, gmodelToQueries
    , modelName, primaryKey
    , LookupRow(..), UpdateRow(..), InsertRow(..)
      -- * Database operations
    , findKey, findRef, save, destroy, destroyByRef
      -- * Low-level functions providing piecemeal access to defaults
    , defaultModelInfo
    , defaultModelTable, defaultModelColumns, defaultModelGetPrimaryKey
    , defaultModelRead, defaultModelWrite
    , defaultModelQueries
    , defaultModelLookupQuery, defaultModelUpdateQuery
    , defaultModelInsertQuery, defaultModelDeleteQuery
      -- * Low-level functions for generic FromRow/ToRow
    , GFromRow(..), defaultFromRow, GToRow(..), defaultToRow
      -- * Helper functions and miscellaneous internals
    , quoteIdent, ShowRefType(..), NormalRef(..), UniqueRef(..)
    ) where

import Control.Applicative
import Control.Monad
import qualified Data.ByteString as S
import qualified Data.ByteString.Char8 as S8
import Data.Char
import Data.Int
import Data.Monoid
import Data.List
import Data.Typeable
import Data.String
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromField
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.ToField
import Database.PostgreSQL.Simple.ToRow
import Database.PostgreSQL.Simple.Types
import GHC.Generics

import Database.PostgreSQL.ORM.RequireSelector

-- | A type large enough to hold database primary keys.  Do not use
-- this type directly in your data structures.  Use 'DBKey' to hold a
-- `Model`'s primary key and 'DBRef' to reference the primary key of
-- another model.
type DBKeyType = Int64

-- | The type of the Haskell data structure field containing a model's
-- primary key.
--
-- Every 'Model' must have exactly one @DBKey@, and the @DBKey@ must
-- be the `Model`'s very first field in the Haskel data type
-- definition.  (The ordering is enforced by
-- 'defaultModelGetPrimaryKey', which, through use of the
-- @DeriveGeneric@ extension, fails to compile when the first field is
-- not a @DBKey@.)
--
-- Each 'Model' stored in the database should have a unique non-null
-- primary key.  However, the key is determined at the time the
-- 'Model' is inserted into the database.  While you are constructing
-- a new 'Model' to insert, you will not have its key.  Hence, you
-- should use the value @NullKey@ to let the database chose the key.
--
-- If you wish to store a `Model`'s primary key as a reference in
-- another 'Model', do not copy the 'DBKey' structure.  Use 'mkDBRef'
-- to convert the `Model`'s primary key to a foreign key reference.
data DBKey = DBKey !DBKeyType | NullKey deriving (Typeable)

instance Eq DBKey where
  (DBKey a) == (DBKey b) = a == b
  _         == _         = error "compare NullKey"
instance Ord DBKey where
  compare (DBKey a) (DBKey b) = compare a b
  compare _ _                 = error "compare NullKey"

instance Show DBKey where
  showsPrec n (DBKey k) = showsPrec n k
  showsPrec _ NullKey   = ("null" ++)
instance Read DBKey where
  readsPrec n s = case readsPrec n s of
    [] | [("null", r)] <- lex s -> [(NullKey, r)]
    kr -> map (\(k, r) -> (DBKey k, r)) kr

instance FromField DBKey where
  fromField _ Nothing = pure NullKey
  fromField f bs      = DBKey <$> fromField f bs
instance ToField DBKey where
  toField (DBKey k) = toField k
  toField NullKey   = toField Null

-- | Returns 'True' when a 'DBKey' is 'NullKey'.
isNullKey :: DBKey -> Bool
isNullKey NullKey = True
isNullKey _       = False


-- | Many operations can take either a 'DBRef' or a 'DBURef' (both of
-- which consist internally of a 'DBKeyType').  Hence, these two types
-- are just type aliases to a generalized reference type @GDBRef@,
-- where @GDBRef@'s first type argument, @reftype@, is a phantom type
-- denoting the flavor of reference ('NormalRef' or 'UniqueRef').
newtype GDBRef reftype table = GDBRef DBKeyType deriving (Typeable)

class ShowRefType rt where showRefType :: r rt t -> String

instance (ShowRefType rt, Model t) => Show (GDBRef rt t) where
  showsPrec n r@(GDBRef k) = showParen (n > 10) $
    (showRefType r ++) . ("{" ++) . (mname ++) . ("} " ++) . showsPrec 11 k
    where mname = S8.unpack $ modelTable $ gmodelToInfo r
instance FromField (GDBRef rt t) where
  {-# INLINE fromField #-}
  fromField f bs = GDBRef <$> fromField f bs
instance ToField (GDBRef rt t) where
  {-# INLINE toField #-}
  toField (GDBRef k) = toField k

data NormalRef = NormalRef deriving (Show, Typeable)
-- | The type @DBRef MyDatabaseTable@ references an instance of the
-- @MyDatabaseTable@ 'Model' by its primary key.  The type argument
-- (i.e., @MyDatabaseTable@ in this case) should be an instance of
-- 'Model'.
type DBRef = GDBRef NormalRef
instance ShowRefType NormalRef where showRefType _ = "DBRef"

data UniqueRef = UniqueRef deriving (Show, Typeable)
-- | A @DBURef MyDatabaseTable@ is like a @'DBRef' MyDatabaseTable@,
-- but with an added uniqeuness constraint.  In other words, if type
-- @A@ contains a @DBURef B@, then each @B@ has one (or at most one)
-- @A@ associated with it.  By contrast, if type @A@ contains a
-- @'DBRef' B@, then each @B@ may be associated with many rows of type
-- @A@.
type DBURef = GDBRef UniqueRef
instance ShowRefType UniqueRef where showRefType _ = "DBURef"

-- | Create a reference to the primary key of a 'Model', suitable for
-- storing in a different 'Model'.
mkDBRef :: (Model a) => a -> GDBRef rt a
mkDBRef a
  | (DBKey k) <- primaryKey a = GDBRef k
  | otherwise = error $ "mkDBRef " ++ S8.unpack (modelName a) ++ ": NullKey"




-- | Every 'Model' has a @ModelInfo@ structure associated with it.
data ModelInfo a = Model {
    modelTable :: !S.ByteString
    -- ^ The name of the database table corresponding to this model.
    -- The default is the same as the type name.
  , modelColumns :: ![S.ByteString]
    -- ^ The name of columns in the database table that corresponds to
    -- this model.  The column names should appear in the order that the
    -- data fields occur in the haskell data type @a@ (or at least the
    -- order in which 'modelRead' parses them).  The default is to use
    -- the Haskell field names for @a@.  This default will fail to
    -- compile if @a@ is not defined using record syntax.
  , modelPrimaryColumn :: !Int
    -- ^ The 0-based index of the primary key column in 'modelColumns'
  , modelGetPrimaryKey :: !(a -> DBKey)
    -- ^ Return the primary key of a particular model instance.
  , modelRead :: !(RowParser a)
    -- ^ Parse a database row corresponding to the model.
  , modelWrite :: !(a -> [Action])
    -- ^ Format all fields except the primary key for writing the
    -- model to the database.
  }

instance Show (ModelInfo a) where
  show a = intercalate " " ["Model", show $ modelTable a
                           , show $ modelColumns a, show $ modelPrimaryColumn a
                           , "???"]

class GDatatypeName f where
  gDatatypeName :: f p -> String
instance (Datatype c) => GDatatypeName (M1 i c f) where 
  gDatatypeName a = datatypeName a
defaultModelTable :: (Generic a, GDatatypeName (Rep a)) => a -> S.ByteString
defaultModelTable = fromString . maybeFold. gDatatypeName . from
  where maybeFold s | h:t <- s, not (any isUpper t) = toLower h:t
                    | otherwise                     = s

class GColumns f where
  gColumns :: f p -> [S.ByteString]
instance GColumns U1 where
  gColumns _ = []
instance (Selector c, RequireSelector c) => GColumns (M1 S c f) where
  gColumns s = [fromString $ selName s]
instance (GColumns a, GColumns b) => GColumns (a :*: b) where
  gColumns ~(a :*: b) = gColumns a ++ gColumns b
instance (GColumns f) => GColumns (M1 C c f) where
  gColumns ~(M1 fp) = gColumns fp
instance (GColumns f) => GColumns (M1 D c f) where
  gColumns ~(M1 fp) = gColumns fp
defaultModelColumns :: (Generic a, GColumns (Rep a)) => a -> [S.ByteString]
defaultModelColumns = gColumns . from

-- | This class extracts the first field in a data structure when the
-- field is of type 'DBKey'.  If you get a compilation error because
-- of this class, then move the 'DBKey' first in your data structure.
class GPrimaryKey0 f where
  gPrimaryKey0 :: f p -> DBKey
instance (Selector c, RequireSelector c) =>
         GPrimaryKey0 (M1 S c (K1 i DBKey)) where
  gPrimaryKey0 (M1 (K1 k)) = k
instance (GPrimaryKey0 a) => GPrimaryKey0 (a :*: b) where
  gPrimaryKey0 (a :*: _) = gPrimaryKey0 a
instance (GPrimaryKey0 f) => GPrimaryKey0 (M1 C c f) where
  gPrimaryKey0 (M1 fp) = gPrimaryKey0 fp
instance (GPrimaryKey0 f) => GPrimaryKey0 (M1 D c f) where
  gPrimaryKey0 (M1 fp) = gPrimaryKey0 fp

-- | Extract the primary key of type 'DBKey' from a model when the
-- 'DBKey' is the first element of the data structure.  Fails to
-- compile if the first field is not of type 'DBKey'.
defaultModelGetPrimaryKey :: (Generic a, GPrimaryKey0 (Rep a)) => a -> DBKey
defaultModelGetPrimaryKey = gPrimaryKey0 . from


class GFromRow f where
  gFromRow :: RowParser (f p)
instance GFromRow U1 where
  gFromRow = return U1
instance (FromField c) => GFromRow (K1 i c) where
  gFromRow = K1 <$> field
instance (GFromRow a, GFromRow b) => GFromRow (a :*: b) where
  gFromRow = (:*:) <$> gFromRow <*> gFromRow
instance (GFromRow f) => GFromRow (M1 i c f) where
  gFromRow = M1 <$> gFromRow
defaultFromRow :: (Generic a, GFromRow (Rep a)) => RowParser a
defaultFromRow = to <$> gFromRow

defaultModelRead :: (Generic a, GFromRow (Rep a)) => RowParser a
defaultModelRead = defaultFromRow


class GToRow f where
  gToRow :: f p -> [Action]
instance GToRow U1 where
  gToRow _ = []
instance (ToField c) => GToRow (K1 i c) where
  gToRow (K1 c) = [toField c]
instance (GToRow a, GToRow b) => GToRow (a :*: b) where
  gToRow (a :*: b) = gToRow a ++ gToRow b
instance (GToRow f) => GToRow (M1 i c f) where
  gToRow (M1 fp) = gToRow fp
defaultToRow :: (Generic a, GToRow (Rep a)) => a -> [Action]
defaultToRow = gToRow . from

deleteAt :: Int -> [a] -> [a]
deleteAt 0 (_:t) = t
deleteAt n (h:t) = h:deleteAt (n-1) t
deleteAt _ _     = []

defaultModelWrite :: (Generic a, GToRow (Rep a)) =>
                     Int        -- ^ Field number of the primary key
                     -> a       -- ^ Model to write
                     -> [Action] -- ^ Writes all fields except primary key
defaultModelWrite pki = deleteAt pki . defaultToRow


defaultModelInfo :: (Generic a, GToRow (Rep a), GFromRow (Rep a)
                    , GPrimaryKey0 (Rep a), GColumns (Rep a)
                    , GDatatypeName (Rep a)) => ModelInfo a
defaultModelInfo = m
  where m = Model { modelTable = mname
                  , modelColumns = cols
                  , modelPrimaryColumn = pki
                  , modelGetPrimaryKey = defaultModelGetPrimaryKey
                  , modelRead = defaultModelRead
                  , modelWrite = defaultModelWrite pki
                  }
        unModel :: ModelInfo a -> a
        unModel _ = undefined
        a = unModel m
        mname = defaultModelTable a
        pki = 0
        cols = defaultModelColumns a

data ModelQueries a = ModelQueries {
    modelLookupQuery :: !Query
    -- ^ A query template for looking up a model by its primary key.
    -- Should expect a single query parameter, namely the 'DBKey'
    -- being looked up.
  , modelUpdateQuery :: !Query
    -- ^ A query template for updating an existing 'Model' in the
    -- database.  Expects as query parameters every column of the
    -- model /except/ the primary key, followed by the primary key.
    -- (The primary key is not written to the database, just used to
    -- select the row to change.)
  , modelInsertQuery :: !Query
    -- ^ A query template for inserting a new 'Model' in the database.
    -- The query parameters are all columns /except/ the primary key.
  , modelDeleteQuery :: !Query
    -- ^ A query template for deleting a 'Model' from the database.
    -- The query paremeter is the primary key of the row to delete.
  } deriving (Show)

quoteIdent :: S.ByteString -> S.ByteString
quoteIdent iden = S8.pack $ '"' : (go $ S8.unpack iden)
  where go ('"':cs) = '"':'"':go cs
        go ('\0':_) = error $ "q: illegal NUL character in " ++ show iden
        go (c:cs)   = c:go cs
        go []       = '"':[]

q :: S.ByteString -> S.ByteString
q = quoteIdent

fmtCols :: Bool -> [S.ByteString] -> S.ByteString
fmtCols False cs = S.intercalate ", " (map q cs)
fmtCols True cs = "(" <> fmtCols False cs <> ")"


defaultModelLookupQuery :: ModelInfo a -> Query
defaultModelLookupQuery mi = Query $ S.concat [
  "select ", fmtCols False (modelColumns mi), " from ", q (modelTable mi)
  , " where ", q (modelColumns mi !! modelPrimaryColumn mi), " = ?"
  ]

defaultModelUpdateQuery :: ModelInfo a -> Query
defaultModelUpdateQuery mi = Query $ S.concat [
    "update ", q (modelTable mi), " set "
    , S.intercalate ", " (map (\c -> q c <> " = ?") $ deleteAt pki cs)
    , " where ", q (cs !! pki), " = ?"
  ]
  where cs = modelColumns mi                        
        pki = modelPrimaryColumn mi

defaultModelInsertQuery :: ModelInfo a -> Query
defaultModelInsertQuery mi = Query $ S.concat $ [
  "insert into ", q (modelTable mi), " ", fmtCols True cs1, " values ("
  , S.intercalate ", " $ map (const "?") cs1
  , ") returning ", fmtCols False cs0
  ]
  where cs0 = modelColumns mi
        cs1 = deleteAt (modelPrimaryColumn mi) cs0

defaultModelDeleteQuery :: ModelInfo a -> Query
defaultModelDeleteQuery mi = Query $ S.concat [
  "delete from ", q (modelTable mi), " where "
  , q (modelColumns mi !! modelPrimaryColumn mi), " = ?"
  ]

defaultModelQueries :: ModelInfo a -> ModelQueries a
defaultModelQueries mi = ModelQueries {
    modelLookupQuery = defaultModelLookupQuery mi
  , modelUpdateQuery = defaultModelUpdateQuery mi
  , modelInsertQuery = defaultModelInsertQuery mi
  , modelDeleteQuery = defaultModelDeleteQuery mi
  }


-- | The class of data types that represent a database table.  This
-- class conveys two important pieces of information necessary to load
-- and save data structures from the database.
--
--   * 'modelInfo' provides information about translating between the
--     Haskell class instance and the database representation, in the
--     form of a 'ModelInfo' data structure.  Among other things, this
--     structure specifies the name of the database table, the names
--     of the database columns corresponding to the Haskell data
--     structure fields, and how to convert the data structure to and
--     from database rows.
--
--   * 'modelQueries' provides pre-formatted 'Query' templates for
--     common operations.  The default 'modelQueries' value is
--     generated from 'modelInfo' and should be suitable for most
--     cases.  Hence, most @Model@ instances should not specify
--     'modelQueries' and should instead perform customization in the
--     definition of 'modelInfo'.
--
-- 'modelInfo' itself provides a reasonable default implementation for
-- types that are members of the 'Generic' class (using GHC's
-- @DeriveGeneric@ extension), provided two conditions hold:
--
--   1. The data type must be defined using record selector syntax.
--
--   2. The very first field of the data type must be a 'DBKey' to
--      represent the primary key.  Other orders will cause a
--      compilation error.
--
-- If both of these conditions hold and your database nameing scheme
-- follows the default conventions, it is reasonable to leave a
-- completely empty (default) instance declaration:
--
-- >   data MyType = MyType { myKey :: !DBKey
-- >                        , ...
-- >                        } deriving (Show, Generic)
-- >   instance Model MyType
--
-- The default 'modelInfo' method is called 'defaultModelInfo'.  You
-- may wish to use almost all of the defaults, but tweak a few things.
-- This is easily accomplished by overriding a few fields of the
-- default structure.  For example, suppose your database columns use
-- exactly the same name as your Haskell field names, but the name of
-- database table is not the same as the name of the Haskell data
-- type.  You can override the database table name (field
-- 'modelTable') as follows:
--
-- >   instance Model MyType where
-- >       modelInfo = defaultModelInfo { modelTable = "my_type" }
--
-- Finally, if you dislike the conventions followed by
-- 'defaultModelInfo', you can simply implement an alternate pattern,
-- say @someOtherPattern@, and use it in place of the default:
--
-- >   instance Model MyType where modelInfo = someOtherPattern
--
-- You can implement @someOtherPattern@ in terms of
-- 'defaultModelInfo', or use some of the lower-level functions from
-- which 'defaultModelInfo' is built.  Each component default function
-- is separately exposed (e.g., 'defaultModelTable',
-- 'defaultModelColumns', 'defaultModelGetPrimaryKey', etc.).
--
-- The default queries are simiarly provided by a default function
-- 'defaultModelQueries', whose individual component functions are
-- exposed ('defaultModelLookupQuery', etc.).  However, customizing
-- the queries is not recommended.
class Model a where
  modelInfo :: ModelInfo a
  default modelInfo :: (Generic a, GToRow (Rep a), GFromRow (Rep a)
                       , GPrimaryKey0 (Rep a), GColumns (Rep a)
                       , GDatatypeName (Rep a)) => ModelInfo a
  {-# INLINE modelInfo #-}
  modelInfo = defaultModelInfo
  modelQueries :: ModelQueries a
  modelQueries = defaultModelQueries modelInfo

modelToInfo :: (Model a) => a -> ModelInfo a
{-# INLINE modelToInfo #-}
modelToInfo _ = modelInfo

gmodelToInfo :: (Model a) => g a -> ModelInfo a
{-# INLINE gmodelToInfo #-}
gmodelToInfo _ = modelInfo

modelToQueries :: (Model a) => a -> ModelQueries a
{-# INLINE modelToQueries #-}
modelToQueries _ = modelQueries

gmodelToQueries :: (Model a) => g a -> ModelQueries a
{-# INLINE gmodelToQueries #-}
gmodelToQueries _ = modelQueries

modelName :: (Model a) => a -> S.ByteString
{-# INLINE modelName #-}
modelName = modelTable . modelToInfo

primaryKey :: (Model a) => a -> DBKey
{-# INLINE primaryKey #-}
primaryKey a = modelGetPrimaryKey modelInfo a


-- | A newtype wrapper in the 'FromRow' class, permitting every model
-- to used as the result of a database query.
newtype LookupRow a = LookupRow { lookupRow :: a } deriving (Show, Typeable)
instance (Model a) => FromRow (LookupRow a) where
  fromRow = LookupRow <$> modelRead modelInfo

-- | A newtype wrapper in the 'ToRow' class, which marshalls every
-- field except the primary key.  For use with 'modelInsertQuery'.
newtype InsertRow a = InsertRow a deriving (Show, Typeable)
instance (Model a) => ToRow (InsertRow a) where
  toRow (InsertRow a) = modelWrite modelInfo a

-- | A newtype wrapper in the 'ToRow' class, which marshalls every
-- field except the primary key, followed by the primary key.  For use
-- with 'modelUpdateQuery'.
newtype UpdateRow a = UpdateRow a deriving (Show, Typeable)
instance (Model a) => ToRow (UpdateRow a) where
  toRow (UpdateRow a) = toRow $ InsertRow a :. Only (primaryKey a)

findKey :: (Model r) => Connection -> DBKey -> IO (Maybe r)
findKey _ NullKey = error "findKey: NullKey"
findKey c k = action
  where getInfo :: (Model r) => IO (Maybe r) -> ModelQueries r
        getInfo _ = modelQueries
        qs = getInfo action
        action = do rs <- query c (modelLookupQuery qs) (Only k)
                    case rs of [r] -> return $ Just $ lookupRow $ r
                               _   -> return Nothing

findRef :: (Model r) => Connection -> GDBRef rt r -> IO (Maybe r)
findRef c (GDBRef k) = findKey c (DBKey k)

-- | Write a 'Model' to the database.  If the primary key is
-- 'NullKey', the item is written with an @INSERT@ query, read back
-- from the database, and returned with its primary key filled in.  If
-- the primary key is not 'NullKey', then the 'Model' is writen with
-- an @UPDATE@ query and returned as-is.
save :: (Model r) => Connection -> r -> IO r
save c r | NullKey <- primaryKey r = do
               rs <- query c (modelInsertQuery qs) (InsertRow r)
               case rs of [r'] -> return $ lookupRow r'
                          _    -> fail "save: database did not return row"
         | otherwise = do
               n <- execute c (modelUpdateQuery qs) (UpdateRow r)
               case n of 1 -> return r
                         _ -> fail $ "save: database updated " ++ show n
                                     ++ " records"
  where qs = modelToQueries r

destroyByRef :: (Model a) => Connection -> GDBRef rt a -> IO ()
destroyByRef c a =
  void $ execute c (modelDeleteQuery $ gmodelToQueries a) (Only a)

destroy :: (Model a) => Connection -> a -> IO ()
destroy c a =
  void $ execute c (modelDeleteQuery $ modelToQueries a) (Only $ primaryKey a)
