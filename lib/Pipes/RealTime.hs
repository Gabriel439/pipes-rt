module Pipes.RealTime (

  -- *Classes for data with attached timestamps
  TimedEvent(..),
  TMinus(..),

  -- *Pipes throttled by their own timestamps
  timeCat,
  relativeTimeCat,
  dropExpired,
  dropRelativeExpired,

  -- *Pipes throttled by you
  steadyCat,
  poissonCat,
  genPoissonCat,
  catAtTimes,
  catAtRelativeTimes,

  -- *Discard leftover result (?)
  dropResult
  
  ) where

import Control.Monad
import Pipes
import Control.Concurrent (threadDelay)
import Data.Time.Clock
import Data.Time.Calendar
import System.Random
import Statistics.Distribution
import Statistics.Distribution.Exponential

{-| Values in TimedEvents can produce a UTCTime, which is the time
    at which the value should be yielded -}
class TimedEvent a where
  timeOf :: a -> UTCTime

{-| Values in TMinus are values that produce a relative-time, which
    is the time passed (in seconds) since the effect was run at which
    the value will be yielded -}
class TMinus a where
  tMinusSec :: a -> Double

{-| Yield values some time after the effect is run,
    according to their relative timestamps.  Assumes that
    values arrive in ascending time order -}
relativeTimeCat :: (TMinus a) => Pipe a a IO r
relativeTimeCat = do
  t0 <- lift getCurrentTime
  forever $ do
    v <- await
    lift $ pauseUntil (doubleToNomDiffTime (tMinusSec v) `addUTCTime` t0)
    yield v

{-| Yield values at the absolute times given by their timestamps.
    Assumes that they arrive in ascending time order. Values with timestamps
    earlier than the starting time of the effect are yielded immediately -}
timeCat :: (TimedEvent a) => Pipe a a IO r
timeCat = forever $ do
    v <- await
    lift $ pauseUntil (timeOf v)
    yield v

{-| Discard events whose timestamps occur before the effect started running,
    instead of yielding them -}
dropExpired :: (TimedEvent a) => Pipe a a IO ()
dropExpired = do
  v <- await
  now <- lift getCurrentTime
  case compare now (timeOf v) of
    GT -> dropExpired
    _  -> return ()

{-| Discard events whose relative timestamps are less than 0 -}
dropRelativeExpired :: (Monad m, TMinus a) => Pipe a a m ()
dropRelativeExpired = do
  v <- await
  when (tMinusSec v < 0) dropRelativeExpired
  
{-| Yield values at steady rate (Hz) -}
steadyCat :: Double -> Pipe a a IO r
steadyCat rate = do
  t0 <- lift getCurrentTime
  aux t0
  where
    dtUTC = doubleToNomDiffTime (1/rate)
    aux t =
      let t' = dtUTC `addUTCTime` t in do
        lift $ pauseUntil t'
        v <- await
        yield v
        aux t'

{-| Constant-rate Poisson process yielding values, randomized by IO -}
poissonCat :: Double -> Pipe a a IO r
poissonCat rate = do
  rSeed <- lift randomIO
  genPoissonCat (mkStdGen rSeed) rate

{-| Constant-rate Poisson process yielding values, seeded by you -}
genPoissonCat :: StdGen -> Double -> Pipe a a IO r
genPoissonCat gen rate = do
  t0 <- lift getCurrentTime
  let (ts,gen') = getNextTimes gen t0
  aux (ts,gen')
  where
    getNextTimes :: StdGen -> UTCTime -> ([UTCTime], StdGen)
    getNextTimes accGen t0 =
      let (rs,g') = randoms' 100 (0,1) accGen
          intervals = map (uniformToExponential rate) rs
          delays = scanl (+) 0 intervals
      in (map (flip addUTCTime t0 . doubleToNomDiffTime) delays, g') :: ([UTCTime], StdGen)
    aux :: ([UTCTime], StdGen) -> Pipe a a IO r
    aux (t:ts, g) =  do
      lift $ pauseUntil t
      v  <- await
      yield v
      case ts of
        [] -> let (ts',g') = getNextTimes g t in aux (ts',g')
        _  -> aux (ts,g)

randoms' :: (Random a) => Int -> (a,a) -> StdGen -> ([a],StdGen)
randoms' nVals vRange gen = aux nVals ([],gen)
  where
    aux 0 (l,g) = (l,g)
    aux n (l,g) = let (v,g') = randomR vRange g in
      aux (n-1) (v:l, g')


{-|Yield values at a set of absolute times.
   Yield remaining values immediately if the
   time list becomes empty -}
catAtTimes :: [UTCTime] -> Pipe a a IO r
catAtTimes []     = cat
catAtTimes (t:ts) = do
  lift $ pauseUntil t
  v <- await
  yield v
  catAtTimes ts

{-|Yield values at a set of times relative to the first received value.
   Yield remaining values immediately if the time list becomes empty -}
catAtRelativeTimes :: [Double] -> Pipe a a IO r
catAtRelativeTimes []       = cat
catAtRelativeTimes ts@(_:_) = lift absTimes >>= catAtTimes 
  where absTimes = 
          getCurrentTime >>= \t0 ->
          return $ map (\d -> doubleToNomDiffTime d `addUTCTime` t0) ts


pauseUntil :: UTCTime -> IO ()
pauseUntil t = do
  now <- getCurrentTime
  case compare now t of
    LT -> threadDelay (truncate (diffUTCTime t now * 1000000))
    _  -> return ()

uniformToExponential :: Double -> Double -> Double
uniformToExponential rate = quantile (exponential rate)

doubleToNomDiffTime :: Double -> NominalDiffTime
doubleToNomDiffTime x =
  let d0 = ModifiedJulianDay 0
      t0 = UTCTime d0 (picosecondsToDiffTime 0)
      t1 = UTCTime d0 (picosecondsToDiffTime $ floor (x/1e-12))
  in  diffUTCTime t1 t0

dropResult :: (Monad m) => Proxy a' a b' b m r -> Proxy a' a b' b m ()
dropResult p = p >>= \_ -> return ()