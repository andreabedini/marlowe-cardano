module Component.Modal.View
  ( modal
  ) where

import Prologue hiding (div)

import Component.ConfirmUnsavedNavigation.View (render) as ConfirmUnsavedNavigation
import Component.Demos.View (render) as Demos
import Component.NewProject.View (render) as NewProject
import Component.Projects as Projects
import Contrib.Halogen.HTML (fromPlainHTML')
import Data.Lens ((^.))
import Debug (traceM)
import Effect.Aff.Class (class MonadAff)
import Halogen (ComponentHTML, RefLabel(..))
import Halogen.Extra (renderSubmodule)
import Halogen.HTML (ClassName(ClassName), div, text)
import Halogen.HTML as HH
import Halogen.HTML.Events (onClick)
import Halogen.HTML.Properties (classes, ref)
import Halogen.Query.Input (Input(..))
import Halogen.Store.Monad (class MonadStore)
import MainFrame.Types
  ( Action(..)
  , ChildSlots
  , ModalView(..)
  , State
  , _newProject
  , _openProject
  , _rename
  , _saveAs
  , _showModal
  )
import MainFrame.Types as Types
import Rename.State (render) as Rename
import SaveAs.State (render) as SaveAs
import Store as Store
import Type.Constraints (class MonadAffAjaxStore)
import Type.Prelude (Proxy(..))
import Web.Event.Event as Event
import Web.HTML.HTMLElement as HTMLElement
import Web.UIEvent.MouseEvent as MouseEvent

_modalContent = Proxy :: Proxy "modalContent"

modal
  :: forall m
   . MonadAffAjaxStore m
  => State
  -> ComponentHTML Action ChildSlots m
modal state = case state ^. _showModal of
  Nothing -> text ""
  Just view ->
    div
      [ classes [ ClassName "modal-backdrop" ]
      , onClick ModalBackdropClick
      , ref Types.modalBackdropLabel
      ]
      [ div [ classes [ ClassName "modal" ] ]
          [ modalContent view ]
      ]
  where

  modalContent = case _ of
    ModalComponent component ->
      HH.slot _modalContent unit component unit CloseModal

    StaticHTML html -> fromPlainHTML' html

    NewProject -> renderSubmodule _newProject NewProjectAction NewProject.render
      state

    --   Canceled -> CloseModal
    --   LoadProject project -> CloseModal
    -- OpenProject -> HH.slot _openProject unit Projects.open unit
    --   (CloseModal <<< map LoadProject)

    OpenDemo -> renderSubmodule identity DemosAction (const Demos.render) state
    RenameProject -> renderSubmodule _rename RenameAction Rename.render state
    -- SaveProjectAs -> do
    --   HH.slot_ _saveProject unit Projects.save unit

    (ConfirmUnsavedNavigation intendedAction) -> ConfirmUnsavedNavigation.render
      intendedAction
      state
-- (GithubLogin intendedAction) -> authButton intendedAction state
