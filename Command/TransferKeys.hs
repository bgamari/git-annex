{- git-annex command, used internally by assistant
 -
 - Copyright 2012, 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}

module Command.TransferKeys where

import Common.Annex
import Command
import Annex.Content
import Logs.Location
import Logs.Transfer
import qualified Remote
import Types.Remote (AssociatedFile)
import Types.Key
import qualified Option

data TransferRequest = TransferRequest Direction Remote Key AssociatedFile

def :: [Command]
def = [withOptions options $
	command "transferkeys" paramNothing seek "plumbing; transfers keys"]

options :: [Option]
options = [readFdOption, writeFdOption]

readFdOption :: Option
readFdOption = Option.field [] "readfd" paramNumber "read from this fd"

writeFdOption :: Option
writeFdOption = Option.field [] "writefd" paramNumber "write to this fd"

seek :: [CommandSeek]
seek = [withField readFdOption convertFd $ \readh ->
	withField writeFdOption convertFd $ \writeh ->
	withNothing $ start readh writeh]

convertFd :: Maybe String -> Annex (Maybe Handle)
convertFd Nothing = return Nothing
convertFd (Just s) = liftIO $ do
	case readish s of
		Nothing -> error "bad fd"
		Just fd -> Just <$> fdToHandle fd

start :: Maybe Handle -> Maybe Handle -> CommandStart
start readh writeh = do
	runRequests (fromMaybe stdin readh) (fromMaybe stdout writeh) runner
	stop
  where
	runner (TransferRequest direction remote key file)
		| direction == Upload = 
			upload (Remote.uuid remote) key file forwardRetry $ \p -> do
				ok <- Remote.storeKey remote key file p
				when ok $
					Remote.logStatus remote key InfoPresent
				return ok
		| otherwise = download (Remote.uuid remote) key file forwardRetry $
			getViaTmp key $ Remote.retrieveKeyFile remote key file

runRequests
	:: Handle
	-> Handle
	-> (TransferRequest -> Annex Bool)
	-> Annex ()
runRequests readh writeh a = go =<< readrequests
  where
  	go (d:u:k:f:rest) = do
		case (deserialize d, deserialize u, deserialize k, deserialize f) of
			(Just direction, Just uuid, Just key, Just file) -> do
				mremote <- Remote.remoteFromUUID uuid
				case mremote of
					Nothing -> sendresult False
					Just remote -> sendresult =<< a
						(TransferRequest direction remote key file)
			_ -> sendresult False
		go rest
	go [] = return ()
	go _ = error "transferkeys protocol error"

	readrequests = liftIO $ split fieldSep <$> hGetContents readh
	sendresult b = liftIO $ do
		hPutStrLn writeh $ serialize b
		hFlush writeh

sendRequest :: TransferRequest -> Handle -> IO ()
sendRequest (TransferRequest d r k f) h = do
	hPutStr h $ join fieldSep
		[ serialize d
		, serialize $ Remote.uuid r
		, serialize k
		, serialize f
		]
	hFlush h

fieldSep :: String
fieldSep = "\0"

class Serialized a where
	serialize :: a -> String
	deserialize :: String -> Maybe a

instance Serialized Bool where
	serialize True = "1"
	serialize False = "0"
	deserialize "1" = Just True
	deserialize "0" = Just False
	deserialize _ = Nothing

instance Serialized Direction where
	serialize Upload = "u"
	serialize Download = "d"
	deserialize "u" = Just Upload
	deserialize "d" = Just Download
	deserialize _ = Nothing

instance Serialized AssociatedFile where
	serialize (Just f) = f
	serialize Nothing = ""
	deserialize "" = Just Nothing
	deserialize f = Just $ Just f

instance Serialized UUID where
	serialize = fromUUID
	deserialize = Just . toUUID

instance Serialized Key where
	serialize = key2file
	deserialize = file2key