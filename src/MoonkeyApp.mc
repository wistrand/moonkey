import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class MoonkeyApp extends Application.AppBase {
    private var _view as AnalogView or Null = null;

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        _view = new AnalogView();
        // Pair a watch-face delegate so the native editor's accent-colour edits
        // preview live (devices with the watch-face editor); harmless elsewhere.
        if (WatchUi has :WatchFaceDelegate) {
            return [_view, new AnalogWatchFaceDelegate(_view)];
        }
        return [_view];
    }

    //! Garmin Connect app-settings changed (beta/store installs): re-apply them.
    //! This is the editor-less path (e.g. MARQ 2) and coexists with the native
    //! editor; both feed the same view setters.
    function onSettingsChanged() as Void {
        if (_view != null) {
            _view.applyProperties();
        }
        WatchUi.requestUpdate();
    }
}
