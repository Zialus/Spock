{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Web.Spock.Core
    ( -- * Lauching Spock
      runSpock, runSpockNoBanner, spockAsApp
      -- * Spock's route definition monad
    , spockT, spockLimT, spockConfigT, SpockT, SpockCtxT
      -- * Defining routes
    , Path, root, Var, var, static, (<//>)
      -- * Rendering routes
    , renderRoute
      -- * Hooking routes
    , subcomponent, prehook
    , get, post, getpost, head, put, delete, patch, hookRoute, hookRouteCustom, hookAny, hookAnyCustom
    , Http.StdMethod (..)
      -- * Adding Wai.Middleware
    , middleware
      -- * Actions
    , module Web.Spock.Action
      -- * Config
    , SpockConfig (..), defaultSpockConfig
      -- * Internals
    , hookRoute', hookAny', SpockMethod(..), W.HttpMethod(..)
    )
where


import Web.Spock.Action
import Web.Spock.Internal.Wire (SpockMethod(..))

import Control.Applicative
import Control.Monad.Reader
import Data.HVect hiding (head)
import Data.Word
import Network.HTTP.Types.Method
import Prelude hiding (head, uncurry, curry)
import Web.Routing.Router (swapMonad)
import Web.Routing.SafeRouting hiding (renderRoute)
import Web.Spock.Internal.Config
import qualified Data.Text as T
import qualified Network.HTTP.Types as Http
import qualified Network.Wai as Wai
import qualified Web.Routing.Router as AR
import qualified Web.Routing.SafeRouting as SR
import qualified Web.Spock.Internal.Wire as W
import qualified Network.Wai.Handler.Warp as Warp

type SpockT = SpockCtxT ()

newtype LiftHooked ctx m =
    LiftHooked { unLiftHooked :: forall a. ActionCtxT ctx m a -> ActionCtxT () m a }

injectHook :: LiftHooked ctx m -> (forall a. ActionCtxT ctx' m a -> ActionCtxT ctx m a) -> LiftHooked ctx' m
injectHook (LiftHooked baseHook) nextHook =
    LiftHooked $ baseHook . nextHook

newtype SpockCtxT ctx m a
    = SpockCtxT
    { runSpockT :: W.SpockAllT m (ReaderT (LiftHooked ctx m) m) a
    } deriving (Monad, Functor, Applicative, MonadIO)

instance MonadTrans (SpockCtxT ctx) where
    lift = SpockCtxT . lift . lift

-- | Run a Spock application. Basically just a wrapper aroung 'Warp.run'.
runSpock :: Warp.Port -> IO Wai.Middleware -> IO ()
runSpock port mw =
    do putStrLn ("Spock is running on port " ++ show port)
       app <- spockAsApp mw
       Warp.run port app

-- | Like 'runSpock', but does not display the banner "Spock is running on port XXX" on stdout.
runSpockNoBanner :: Warp.Port -> IO Wai.Middleware -> IO ()
runSpockNoBanner port mw =
    do app <- spockAsApp mw
       Warp.run port app

-- | Convert a middleware to an application. All failing requests will
-- result in a 404 page
spockAsApp :: IO Wai.Middleware -> IO Wai.Application
spockAsApp = liftM W.middlewareToApp

-- | Create a raw spock application with custom underlying monad
-- Use @runSpock@ to run the app or @spockAsApp@ to create a @Wai.Application@
-- The first argument is request size limit in bytes. Set to 'Nothing' to disable.
spockT :: (MonadIO m)
       => (forall a. m a -> IO a)
       -> SpockT m ()
       -> IO Wai.Middleware
spockT = spockConfigT defaultSpockConfig

-- | Like @spockT@, but first argument is request size limit in bytes. Set to 'Nothing' to disable.
{-# DEPRECATED spockLimT "Consider using spockConfigT instead" #-}
spockLimT :: forall m .MonadIO m
       => Maybe Word64
       -> (forall a. m a -> IO a)
       -> SpockT m ()
       -> IO Wai.Middleware
spockLimT mSizeLimit  =
    let spockConfigWithLimit = defaultSpockConfig { sc_maxRequestSize = mSizeLimit }
    in spockConfigT spockConfigWithLimit

-- | Like @spockT@, but with additional configuration for request size and error
-- handlers passed as first parameter.
spockConfigT :: forall m .MonadIO m
        => SpockConfig
        -> (forall a. m a -> IO a)
        -> SpockT m ()
        -> IO Wai.Middleware
spockConfigT (SpockConfig maxRequestSize errorAction) liftFun app =
    W.buildMiddleware internalConfig liftFun (baseAppHook app)
  where
    internalConfig = W.SpockConfigInternal maxRequestSize errorHandler
    errorHandler status = spockAsApp $ W.buildMiddleware W.defaultSpockConfigInternal id $ baseAppHook $ errorApp status
    errorApp status = mapM_ (\method -> hookAny method $ \_ -> errorAction' status) [minBound .. maxBound]
    errorAction' status = setStatus status >> errorAction status

baseAppHook :: forall m. MonadIO m => SpockT m () -> W.SpockAllT m m ()
baseAppHook app =
    swapMonad lifter (runSpockT app)
    where
      lifter :: forall b. ReaderT (LiftHooked () m) m b -> m b
      lifter action = runReaderT action (LiftHooked id)

-- | Specify an action that will be run when the HTTP verb 'GET' and the given route match
get :: (HasRep xs, MonadIO m) => Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
get = hookRoute GET

-- | Specify an action that will be run when the HTTP verb 'POST' and the given route match
post :: (HasRep xs, MonadIO m) => Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
post = hookRoute POST

-- | Specify an action that will be run when the HTTP verb 'GET'/'POST' and the given route match
getpost :: (HasRep xs, MonadIO m) => Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
getpost r a = hookRoute POST r a >> hookRoute GET r a

-- | Specify an action that will be run when the HTTP verb 'HEAD' and the given route match
head :: (HasRep xs, MonadIO m) => Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
head = hookRoute HEAD

-- | Specify an action that will be run when the HTTP verb 'PUT' and the given route match
put :: (HasRep xs, MonadIO m) => Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
put = hookRoute PUT

-- | Specify an action that will be run when the HTTP verb 'DELETE' and the given route match
delete :: (HasRep xs, MonadIO m) => Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
delete = hookRoute DELETE

-- | Specify an action that will be run when the HTTP verb 'PATCH' and the given route match
patch :: (HasRep xs, MonadIO m) => Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
patch = hookRoute PATCH

-- | Specify an action that will be run before all subroutes. It can modify the requests current context
prehook :: forall m ctx ctx'. MonadIO m => ActionCtxT ctx m ctx' -> SpockCtxT ctx' m () -> SpockCtxT ctx m ()
prehook hook (SpockCtxT hookBody) =
    SpockCtxT $
    do prevHook <- lift ask
       let newHook :: ActionCtxT ctx' m a -> ActionCtxT ctx m a
           newHook act =
               do newCtx <- hook
                  runInContext newCtx act
           hookLift :: forall a. ReaderT (LiftHooked ctx' m) m a -> ReaderT (LiftHooked ctx m) m a
           hookLift a =
               lift $ runReaderT a (injectHook prevHook newHook)
       swapMonad hookLift hookBody

-- | Specify an action that will be run when a standard HTTP verb and the given route match
hookRoute :: forall xs ctx m. (HasRep xs, Monad m) => StdMethod -> Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
hookRoute = hookRoute' . MethodStandard . W.HttpMethod

-- | Specify an action that will be run when a custom HTTP verb and the given route match
hookRouteCustom :: forall xs ctx m. (HasRep xs, Monad m) => T.Text -> Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
hookRouteCustom = hookRoute' . MethodCustom

-- | Specify an action that will be run when a HTTP verb and the given route match
hookRoute' :: forall xs ctx m. (HasRep xs, Monad m) => SpockMethod -> Path xs -> HVectElim xs (ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
hookRoute' m path action =
    SpockCtxT $
    do hookLift <- lift $ asks unLiftHooked
       let actionPacker :: HVectElim xs (ActionCtxT ctx m ()) -> HVect xs -> ActionCtxT () m ()
           actionPacker act captures = hookLift (uncurry act captures)
       AR.hookRoute m path (HVectElim' $ curry $ actionPacker action)

-- | Specify an action that will be run when a standard HTTP verb matches but no defined route matches.
-- The full path is passed as an argument
hookAny :: Monad m => StdMethod -> ([T.Text] -> ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
hookAny = hookAny' . MethodStandard . W.HttpMethod

-- | Specify an action that will be run when a custom HTTP verb matches but no defined route matches.
-- The full path is passed as an argument
hookAnyCustom :: Monad m => T.Text -> ([T.Text] -> ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
hookAnyCustom = hookAny' . MethodCustom

-- | Specify an action that will be run when a HTTP verb matches but no defined route matches.
-- The full path is passed as an argument
hookAny' :: Monad m => SpockMethod -> ([T.Text] -> ActionCtxT ctx m ()) -> SpockCtxT ctx m ()
hookAny' m action =
    SpockCtxT $
    do hookLift <- lift $ asks unLiftHooked
       AR.hookAny m (hookLift . action)

-- | Define a subcomponent. Usage example:
--
-- > subcomponent "site" $
-- >   do get "home" homeHandler
-- >      get ("misc" <//> var) $ -- ...
-- > subcomponent "admin" $
-- >   do get "home" adminHomeHandler
--
-- The request \/site\/home will be routed to homeHandler and the
-- request \/admin\/home will be routed to adminHomeHandler
subcomponent :: Monad m => Path '[] -> SpockCtxT ctx m () -> SpockCtxT ctx m ()
subcomponent p (SpockCtxT subapp) = SpockCtxT $ AR.subcomponent p subapp

-- | Hook wai middleware into Spock
middleware :: Monad m => Wai.Middleware -> SpockCtxT ctx m ()
middleware = SpockCtxT . AR.middleware

-- | Combine two path components
(<//>) :: Path as -> Path bs -> Path (Append as bs)
(<//>) = (</>)

-- | Render a route applying path pieces
renderRoute :: Path as -> HVectElim as T.Text
renderRoute route = curryExpl (pathToRep route) (T.cons '/' . SR.renderRoute route)
