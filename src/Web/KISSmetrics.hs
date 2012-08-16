-- | This module is meant to be imported qualified:
--
-- @
-- import qualified Web.KISSmetrics as KISSmetrics
-- @
module Web.KISSmetrics
    ( -- * Data types
      APIKey
    , SimpleText
    , Property
    , Timestamp(..)
    , generateTimestamp
      -- * Making calls
    , call
    , CallType(..)
      -- * Type classes
    , EventName(..)
    , Identity(..)
    ) where

import Control.Applicative ((<$>))
import Control.Arrow (second)
import Data.Text (Text)
import Data.Time (UTCTime, formatTime, getCurrentTime)
import Data.Typeable (Typeable)
import qualified Data.ByteString.Char8 as B8
import qualified Data.Conduit as C
import qualified Data.Conduit.List as CL
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Conduit as H
import qualified Network.HTTP.Types as H


-- | Your KISSmetrics API key.
type APIKey = B8.ByteString


-- | KISSmetrics names and identities are limited to at most 255
-- characters and all commas (@,@) and colons (@:@) are changed
-- to spaces (@ @).  Nothing is checked by this Haskell library,
-- so be careful =).
type SimpleText = B8.ByteString


-- | A KISSmetrics property.  The property names needs to follow
-- the rules outlined on 'SimpleText'@s@ documentation.  The
-- property value, on the other hand, are only limited to 8 KiB
-- and don't have any other restrictions.
type Property = (SimpleText, Text)


-- | A timestamp used only to ignore duplicated events.
data Timestamp =
    Automatic
    -- ^ Use KISSmetrics' servers time as the timestamp.
  | Manual UTCTime
    -- ^ Use given time as the timestamp.  If possible, use
    -- 'Manual' since it allows you to safely resend events that
    -- appear to have failed without being afraid of duplicates.
    -- See also 'generateTimestamp'.
    deriving (Eq, Ord, Show, Read, Typeable)


-- | Generate a 'Manual' timestamp with the current time.
generateTimestamp :: IO Timestamp
generateTimestamp = Manual <$> getCurrentTime


-- | A type of call that may be made to KISSmetrics.  It's
-- defined as a GADT where event names and identities are
-- existential values.
--
-- Since Haddock currently has problems with GADTs, here's the
-- documentation about each constructor:
--
--  ['Record'] Record an event.  'eventName' is the name of the
--  event being recorded, 'identity' is the identity of the
--  person doing the event and 'properties' are any other
--  optional properties you may want.
--
--  ['SetProps'] Set user properties without recording an event.
--  'identity' is the identity of the person whose properties
--  will be changed and 'properties' are the properties to be
--  set.
--
--  ['Alias'] Alias two identities ('identity' and 'identity'')
--  as the same one.
--
-- See also <http://support.kissmetrics.com/apis/specifications>.
data CallType where
  Record
    :: (EventName event, Identity ident) =>
       { eventName :: event
       , identity :: ident
       , timestamp :: Timestamp
       , properties :: [Property]
       }
    -> CallType
  SetProps
    :: Identity ident =>
       { identity :: ident
       , timestamp :: Timestamp
       , properties :: [Property]
       }
    -> CallType
  Alias
    :: (Identity ident, Identity ident') =>
       { identity :: ident
       , identity' :: ident'
       }
    -> CallType
  deriving (Typeable)

-- Needs to use StandaloneDeriving since CallType is a GADT.
deriving instance Show CallType


-- | Type class of data types that are event names.
--
-- You may just use 'SimpleText' (which is the only instance
-- provided by default), but you may also create your own data
-- type for event names and add an instance of this class.
class Show event => EventName event where
  fromEventName :: event -> SimpleText

-- | This is the same as 'SimpleText'.
instance EventName B8.ByteString where
  fromEventName = id


-- | Type class of data types that are user identities.
--
-- You may just use 'SimpleText' (which is the only instance
-- provided by default), but you may also create your own data
-- type for event names and add an instance of this class.
class Show ident => Identity ident where
  fromIdentity :: ident -> SimpleText

-- | This is the same as 'SimpleText'.
instance Identity B8.ByteString where
  fromIdentity = id


-- | Call KISSmetrics' API.  See 'CallType' for documentation
-- about which calls you may make.
--
-- KISSmetrics does not return errors even when an error occurs
-- and there's absolutely no way of knowing if your request went
-- through.  However, this function /may/ throw an exception if
-- we fail to make the request to KISSmetrics (e.g. if there's a
-- problem with your server's Internet connection).
--
-- Note that official KISSmetrics' APIs provide many functions
-- (usually four) while we provide just this one and a sum data
-- type.  This function alone does the work of @record@, @set@,
-- @identify@ and @alias@.
--
-- TODO: Currently there's no support for automatically retrying
-- failed request, you need to retry yourself.
call :: H.Manager -- ^ HTTP connection manager (cf. 'H.newManager').
     -> APIKey    -- ^ Your KISSmetrics API key.
     -> CallType  -- ^ Which call you would like to make.
     -> IO ()
call manager apikey callType =
  C.runResourceT $ do
    -- Create the request
    let (path, args) = callInfo callType
        request =
          H.def { H.method = "GET"
                , H.secure = True
                , H.host   = "trk.kissmetrics.com"
                , H.port   = 443
                , H.path   = path
                , H.queryString =
                    H.renderSimpleQuery False $
                    ("_k", apikey) : args
                , H.redirectCount = 0
                }

    -- Make the call
    H.Response {..} <- H.http request manager

    -- KISSmetrics always returns 200 Ok with an invisible 1x1
    -- GIF.  We need to consume the body in order to let the
    -- connection be reused via keep-alive.
    responseBody C.$$+- CL.sinkNull


-- | Internal function.  Given a 'CallType', return the URL to be
-- used and generate a list of arguments.
callInfo :: CallType -> (B8.ByteString, H.SimpleQuery)
callInfo Record {..} =
  ( "/e"
  , (:) ("_n", fromEventName eventName) $
    (:) ("_p", fromIdentity  identity)  $
    timestampInfo timestamp $
    propsInfo properties
  )
callInfo SetProps {..} =
  ( "/s"
  , (:) ("_p", fromIdentity identity) $
    timestampInfo timestamp $
    propsInfo properties
  )
callInfo Alias {..} =
  ( "/a"
  , [ ("_p", fromIdentity identity)
    , ("_n", fromIdentity identity')
    ]
  )


-- | Generate a difference list of arguments for a timestamp.
timestampInfo :: Timestamp
              -> (H.SimpleQuery -> H.SimpleQuery) -- ^ Difference list.
timestampInfo Automatic = id
timestampInfo (Manual t) =
  (:) ("_d", "1") .
  (:) ("_t", B8.pack $ formatTime locale "%s" t)
    where locale = error "Web.KISSmetrics.timestampInfo: locale shouldn't be needed."


-- | Generate a list of arguments for a list of properties.
propsInfo :: [Property] -> H.SimpleQuery
propsInfo = map (second TE.encodeUtf8)
