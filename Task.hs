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
import Control.Concurrent.Async (withAsync, waitCatch)
import Control.Concurrent.STM
import Control.Exception

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
    { runTask :: IO (TaskValue mod d a) }

data TaskValue mod (d :: Nat) a where
    Pure  :: a -> TaskValue mod d a
    Call  :: (Module mod', d' + 1 <= d) => Task mod' d' b -> (b -> Task mod d a) -> TaskValue mod d a
    Send  :: Module mod' => Task mod' d' () -> Task mod d a -> TaskValue mod d a
    Async :: IO b -> (Either SomeException b -> Task mod d a) -> TaskValue mod d a

instance Functor (Task mod d) where
    fmap f (Task m) = Task $ flip fmap m $ \case
        Pure v        -> Pure        $ f v
        Call remote k -> Call remote $ fmap f . k
        Send remote v -> Send remote $ fmap f v
        Async op k    -> Async op    $ fmap f . k

instance Applicative (Task mod d) where
    pure = Task . pure . Pure
    -- TODO better impl (parallel calls)?
    f <*> m = f >>= \f' -> m >>= \a -> pure (f' a)

instance Monad (Task mod d) where
    (Task t) >>= f = Task
        ( t >>= \case
            Pure v        -> runTask $ f v
            Call remote k -> pure $ Call remote $ k >=> f
            Send remote m -> pure $ Send remote $ m >>= f
            Async op k    -> pure $ Async op    $ k >=> f
        )

instance MonadIO (Task mod d) where
    -- TODO: this is unsafe, the IO op might throw, consider using Async for everything
    liftIO = Task . fmap Pure

call :: (Module mod', d' + 1 <= d) => Task mod' d' a -> Task mod d a
call t = Task $ pure $ Call t pure

send :: Module mod' => Task mod' d' () -> Task mod d ()
send t = Task $ pure $ Send t $ pure ()

async :: IO a -> Task mod d (Either SomeException a)
async op = Task $ pure $ Async op pure

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
    msg <- mrecv @mod
    process i msg

process :: Module mod => Int -> Msg mod -> IO ()
process i (Msg (Task t) resp) = do
    dbg $ "recvd " ++ show i ++ ", resp len: " ++ show (lenResp resp)
    t >>= \case
        Pure v -> dbg "Pure" >> case resp of
            NoResponse ->
                dbg ("no response " ++ show i)
            WithResponse k resp' -> do
                dbg ("response " ++ show i)
                msend $ Msg (k v) resp'
        Call remote k -> do
            dbg $ "call " ++ show i
            msend $ Msg remote $ WithResponse k resp
            dbg $ "called" ++ show i
        Send remote m -> do
            dbg $ "send " ++ show i
            msend $ Msg remote NoResponse
            dbg $ "sent remote " ++ show i
            msend $ Msg m resp
            dbg $ "sent to myself " ++ show i
        Async op k -> (=<<) (\_ -> pure ()) $ forkIO $ do
            res <- withAsync op waitCatch
            msend $ Msg (k res) resp

msend :: Module mod => Msg mod -> IO ()
msend msg = do
    let (Mailbox tq) = mailbox
    atomically $ modifyTVar tq (push msg)

mrecv :: Module mod => IO (Msg mod)
mrecv = atomically $ do
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

testasync :: Task M1 0 ()
testasync = do
    liftIO $ putStrLn $ "testasync start"
    res <- async $ do
        liftIO $ putStrLn $ "async thread start"
        _ <- error $ "error!"
        threadDelay 5000000
        liftIO $ putStrLn $ "async thread stop"
        pure (5 :: Int)
    case res of
        Left err -> liftIO $ putStrLn $ "testasync err: " ++ show err
        Right v  -> liftIO $ putStrLn $ "testasync val: " ++ show v

test1 :: Task M1 0 ()
test1 = send $ f1 0

f1 :: Int -> Task M2 0 ()
f1 x = do
    liftIO $ putStrLn $ "f1 " ++ show x
    send $ g1 (x + 1)
    liftIO $ putStrLn $ "f1 sent " ++ show (x + 1) ++ " to g1"

g1 :: Int -> Task M1 0 ()
g1 x = do
    liftIO $ putStrLn $ "g1 " ++ show x
    send $ f1 (x + 1)
    liftIO $ putStrLn $ "g1 sent " ++ show (x + 1) ++ " to f1"

test2 :: Task M2 1 ()
test2 = liftIO (newIORef 0) >>= send . f2

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

    msend $ Msg test1 NoResponse
    msend $ Msg test2 NoResponse
    msend $ Msg testasync NoResponse
    _ <- forkIO $ executor 1 (Proxy :: Proxy M1)
    executor 2 (Proxy :: Proxy M2)
