{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}

module Main where

import Data.Proxy
import Control.Monad
import Control.Monad.IO.Class

import Data.IORef
import Control.Concurrent
import Control.Concurrent.STM

import GHC.TypeLits

import System.IO.Unsafe

data Queue a = Queue
    { front :: [a]
    , back  :: [a]
    }

push :: a -> Queue a -> Queue a
push x q@Queue{..} = q { back = x : back }

pop :: Queue a -> Maybe (Queue a, a)
pop q@Queue{..} = case front of
    (x:xs) -> Just (q { front = xs }, x)
    _      -> case back of
            [] -> Nothing
            _  -> let (y:ys) = reverse back
                  in Just (Queue { front = ys, back = [] }, y)

emptyQ :: Queue a
emptyQ = Queue { front = [], back = [] }

newtype Task mod (d :: Nat) a = Task
    { runTask :: IO (Either (Call mod d a) a) }

data Call mod (d :: Nat) a where
    Call :: (Module mod', d' + 1 <= d) => Task mod' d' b -> (b -> Task mod d a) -> Call mod d a

instance Functor (Task mod d) where
    fmap f (Task m) = Task $ flip fmap m $ \case
        Left (Call remote k) -> Left  $ Call remote $ fmap f . k
        Right v           -> Right $ f v

instance Applicative (Task mod d) where
    pure = Task . pure . Right
    -- TODO better impl (parallel calls)?
    f <*> m = f >>= \f' -> m >>= \a -> pure (f' a)

instance Monad (Task mod d) where
    (Task m) >>= f = Task
        ( m >>= \case
             Left (Call remote k) -> pure $ Left $ Call remote (k >=> f)
             Right v           -> runTask $ f v
        )

instance MonadIO (Task mod d) where
    liftIO = Task . fmap Right

call :: (Module mod', d' + 1 <= d) => Task mod' d' a -> Task mod d a
call t = Task $ pure $ Left $ Call t pure

data ResponseChain a b where
    NoResponse   :: ResponseChain () b
    WithResponse :: Module mod => (a -> Task mod d c) -> ResponseChain c b -> ResponseChain a c

data Msg mod where
    Msg :: Task mod d a -> ResponseChain a b -> Msg mod

newtype Mailbox mod
    = Mailbox { mail :: TVar (Queue (Msg mod)) }

class Module mod where
    mailbox :: Mailbox mod

lenResp :: ResponseChain a b -> Int
lenResp NoResponse = 0
lenResp (WithResponse _ r) = lenResp r + 1

isdbg :: Bool
isdbg = False

dbg :: String -> IO ()
dbg s = if isdbg then putStrLn s else pure ()

executor :: Module mod => Int -> Proxy mod -> IO ()
executor i (_ :: Proxy mod) = forever $ do
    threadDelay 1000000
    dbg ("loop " ++ show i)
    msg <- recv @mod
    process i msg

process :: Module mod => Int -> Msg mod -> IO ()
process i (Msg (Task t) resp) = do
    dbg $ "recvd " ++ show i ++ ", resp len: " ++ show (lenResp resp)
    t >>= \case
        Left (Call remote k) -> do
            dbg $ "call " ++ show i
            send $ Msg remote $ WithResponse k resp
            dbg $ "call sent " ++ show i
        Right v -> dbg "val" >> case resp of
            NoResponse           ->
                dbg ("no resp " ++ show i)
            WithResponse k resp' -> do
                dbg ("resp" ++ show i)
                send $ Msg (k v) resp'

send :: Module mod => Msg mod -> IO ()
send msg = do
    let (Mailbox tq) = mailbox
    dbg "sending"
    atomically $ modifyTVar tq (push msg)
    dbg "sent"

recv :: Module mod => IO (Msg mod)
recv = atomically $ do
    let (Mailbox tq) = mailbox
    q <- readTVar tq
    case pop q of
        Just (q', v) -> writeTVar tq q' >> pure v
        Nothing      -> retry

data M1
data M2

m1box :: Mailbox M1
m1box = Mailbox $ unsafePerformIO $ atomically $ newTVar emptyQ

m2box :: Mailbox M2
m2box = Mailbox $ unsafePerformIO $ atomically $ newTVar emptyQ

-- TODO use something like Data.Reflection to dynamically create mailboxes at startup?
instance Module M1 where
    mailbox = m1box

instance Module M2 where
    mailbox = m2box

-- TODO: f1 + g1 = memory leak (infinite response chain)
-- limit length of response chain
-- introduce CallWithoutResponse?
-- or somehow make calling 'Task mod ()' automatically a call without response
--test1 :: Task M1 ()
--test1 = call $ f1 0
--
--f1 :: Int -> Task M2 ()
--f1 x = do
--    liftIO $ putStrLn $ "f1 " ++ show x
--    call $ g1 (x + 1)
--
--g1 :: Int -> Task M1 ()
--g1 x = do
--    liftIO $ putStrLn $ "g1 " ++ show x
--    call $ f1 (x + 1)

test2 :: Task M2 2 ()
test2 = liftIO (newIORef 0) >>= call . f2

f2 :: IORef Int -> Task M1 1 ()
f2 st = forever $ do
    x <- liftIO $ readIORef st
    liftIO $ putStrLn $ "f2: x = " ++ show x
    y <- call $ g2 x
    liftIO $ putStrLn $ "f2: g2(x) returned " ++ show y
    liftIO $ writeIORef st y

g2 :: Int -> Task M2 0 Int
g2 x = do
    liftIO $ putStrLn $ "g2: x = " ++ show x
    pure (x + 1)

main :: IO ()
main = do
    -- initialize the mailboxes...
    _ <- case m1box of
        Mailbox b -> b `seq` pure ()
    _ <- case m2box of
        Mailbox b -> b `seq` pure ()

    --send $ Msg test1 NoResponse
    send $ Msg test2 NoResponse
    _ <- forkIO $ executor 1 (Proxy :: Proxy M1)
    executor 2 (Proxy :: Proxy M2)
