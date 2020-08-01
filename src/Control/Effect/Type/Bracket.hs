{-# LANGUAGE CPP #-}
{-# OPTIONS_HADDOCK not-home #-}
module Control.Effect.Type.Bracket where

import Control.Effect.Internal.Union
import Control.Effect.Internal.Utils
import Control.Effect.Internal.Reflection
import Control.Effect.Internal.ViaAlg
-- import qualified Control.Exception as X
import Control.Monad.Catch (MonadThrow, MonadCatch, MonadMask, ExitCase(..))
import qualified Control.Monad.Catch as C
-- import Control.Applicative
import Control.Monad.Trans.Reader (ReaderT)
import Control.Monad.Trans.Except (ExceptT)
import qualified Control.Monad.Trans.State.Strict as SSt
import qualified Control.Monad.Trans.State.Lazy as LSt
import qualified Control.Monad.Trans.Writer.Lazy as LWr
import qualified Control.Monad.Trans.Writer.Strict as SWr
import qualified Control.Monad.Trans.Writer.CPS as CPSWr


-- | An effect for exception-safe acquisition and release of resources.
--
-- **'Bracket' is typically used as a primitive effect**.
-- If you define your own novel, non-trivial 'Control.Effect.Carrier',
-- then you need to make a @'ThreadsEff' 'Bracket'@ instance for it (if possible).
data Bracket m a where
  GeneralBracket :: m a
                 -> (a -> ExitCase b -> m c)
                 -> (a -> m b)
                 -> Bracket m (b, c)

instance Monad m => MonadThrow (ViaAlg s Bracket m) where
  throwM = error "threadBracketViaClass: Transformers threading Bracket \
                 \are not allowed to use throwM."
instance Monad m => MonadCatch (ViaAlg s Bracket m) where
  catch = error "threadBracketViaClass: Transformers threading Bracket \
                 \are not allowed to use catch."

instance ( Reifies s (ReifiedEffAlgebra Bracket m)
         , Monad m
         )
       => MonadMask (ViaAlg s Bracket m) where
  mask m = m id
  uninterruptibleMask m = m id

  generalBracket acquire release use = case reflect @s of
    ReifiedEffAlgebra alg -> coerceAlg alg (GeneralBracket acquire release use)
  {-# INLINE generalBracket #-}

-- | A valid definition of 'threadEff' for a @'ThreadsEff' 'Bracket' t@ instance,
-- given that @t@ lifts @'MonadMask'@.
--
-- **BEWARE**: 'threadBracketViaClass' is only safe if the implementation of
-- 'generalBracket' for @t m@ only makes use of 'generalBracket' for @m@, and no
-- other methods of 'MonadThrow', 'MonadCatch', or 'MonadMask'.
threadBracketViaClass :: forall t m a
                       . Monad m
                      => ( RepresentationalT t
                         , forall b. MonadMask b => MonadMask (t b)
                         )
                      => (forall x. Bracket m x -> m x)
                      -> Bracket (t m) a -> t m a
threadBracketViaClass alg (GeneralBracket acquire release use) =
  reify (ReifiedEffAlgebra alg) $ \(_ :: pr s) ->
    unViaAlgT @s @Bracket $
      C.generalBracket
        (viaAlgT acquire)
        ((viaAlgT .) #. release)
        (viaAlgT #. use)
{-# INLINE threadBracketViaClass #-}


#define THREAD_BRACKET(monadT)             \
instance ThreadsEff Bracket (monadT) where \
  threadEff = threadBracketViaClass;       \
  {-# INLINE threadEff #-}

#define THREAD_BRACKET_CTX(ctx, monadT)             \
instance (ctx) => ThreadsEff Bracket (monadT) where \
  threadEff = threadBracketViaClass;                \
  {-# INLINE threadEff #-}


THREAD_BRACKET(ReaderT i)
THREAD_BRACKET(ExceptT e)
THREAD_BRACKET(LSt.StateT s)
THREAD_BRACKET(SSt.StateT s)
THREAD_BRACKET_CTX(Monoid s, LWr.WriterT s)
THREAD_BRACKET_CTX(Monoid s, SWr.WriterT s)

instance Monoid s => ThreadsEff Bracket (CPSWr.WriterT s) where
  threadEff alg (GeneralBracket acq rel use) = CPSWr.writerT $
      fmap (\( (b,sUse), (c,sEnd) ) -> ((b, c), sUse <> sEnd))
    . alg $
      GeneralBracket
        (CPSWr.runWriterT acq)
        (\(a, _) ec -> CPSWr.runWriterT $ rel a $ case ec of
          ExitCaseSuccess (b, _) -> ExitCaseSuccess b
          ExitCaseException exc  -> ExitCaseException exc
          ExitCaseAbort          -> ExitCaseAbort
        )
        (\(a, s) -> CPSWr.runWriterT (CPSWr.tell s >> use a))
  {-# INLINE threadEff #-}

{-
instance ThreadsEff Bracket (ReaderT i) where
  threadEff alg (GeneralBracket acq rel use) = ReaderT $ \s ->
    alg $
      GeneralBracket
        (runReaderT acq s)
        (\a ec -> runReaderT (rel a ec) s)
        (\a -> runReaderT (use a) s)
  {-# INLINE threadEff #-}

instance ThreadsEff Bracket (ExceptT e) where
  threadEff alg (GeneralBracket acq rel use) = ExceptT $
      fmap (uncurry (liftA2 (,)))
    . alg $
        GeneralBracket
          (runExceptT acq)
          (\ea ec -> case ea of
            Left e -> return (Left e)
            Right a -> runExceptT $ case ec of
              ExitCaseSuccess (Right b) ->
                rel a (ExitCaseSuccess b)
              ExitCaseException exc ->
                rel a (ExitCaseException exc)
              _ -> -- Either ExceptT has failed, or something more global has failed
                rel a ExitCaseAbort
          )
          (\ea -> case ea of
            Left e -> return (Left e)
            Right a -> runExceptT (use a)
          )
  {-# INLINE threadEff #-}

instance ThreadsEff Bracket (SSt.StateT s) where
  threadEff alg (GeneralBracket acq rel use) = SSt.StateT $ \sInit ->
      fmap (\( (b,_), (c,sEnd) ) -> ((b, c), sEnd))
    . alg $
      GeneralBracket
        (SSt.runStateT acq sInit)
        (\(a, s) ec -> case ec of
            ExitCaseSuccess (b, s') ->
              SSt.runStateT (rel a (ExitCaseSuccess b)) s'
            ExitCaseException exc ->
              SSt.runStateT (rel a (ExitCaseException exc)) s
            ExitCaseAbort ->
              SSt.runStateT (rel a ExitCaseAbort) s
        )
        (\(a, s) -> SSt.runStateT (use a) s)
  {-# INLINE threadEff #-}

instance ThreadsEff Bracket (LSt.StateT s) where
  threadEff alg (GeneralBracket acq rel use) = LSt.StateT $ \sInit ->
      fmap (\ ~( ~(b,_), ~(c,sEnd) ) -> ((b, c), sEnd))
    . alg $
      GeneralBracket
        (LSt.runStateT acq sInit)
        (\ ~(a, s) ec -> case ec of
            ExitCaseSuccess (~(b, s')) ->
              LSt.runStateT (rel a (ExitCaseSuccess b)) s'
            ExitCaseException exc ->
              LSt.runStateT (rel a (ExitCaseException exc)) s
            ExitCaseAbort ->
              LSt.runStateT (rel a ExitCaseAbort) s
        )
        (\ ~(a, s) -> LSt.runStateT (use a) s)
  {-# INLINE threadEff #-}

instance Monoid s => ThreadsEff Bracket (LWr.WriterT s) where
  threadEff alg (GeneralBracket acq rel use) = LWr.WriterT $
      fmap (\ ~( ~(b,sUse), ~(c,sEnd) ) -> ((b, c), sUse <> sEnd))
    . alg $
      GeneralBracket
        (LWr.runWriterT acq)
        (\ ~(a, _) ec -> LWr.runWriterT $ rel a $ case ec of
          ExitCaseSuccess ~(b, _) -> ExitCaseSuccess b
          ExitCaseException exc   -> ExitCaseException exc
          ExitCaseAbort           -> ExitCaseAbort
        )
        (\ ~(a, s) -> LWr.runWriterT (LWr.tell s >> use a))
  {-# INLINE threadEff #-}

instance Monoid s => ThreadsEff Bracket (SWr.WriterT s) where
  threadEff alg (GeneralBracket acq rel use) = SWr.WriterT $
      fmap (\( (b,sUse), (c,sEnd) ) -> ((b, c), sUse <> sEnd))
    . alg $
      GeneralBracket
        (SWr.runWriterT acq)
        (\(a, _) ec -> SWr.runWriterT $ rel a $ case ec of
          ExitCaseSuccess (b, _) -> ExitCaseSuccess b
          ExitCaseException exc  -> ExitCaseException exc
          ExitCaseAbort          -> ExitCaseAbort
        )
        (\(a, s) -> SWr.runWriterT (SWr.tell s >> use a))
  {-# INLINE threadEff #-}

-}
