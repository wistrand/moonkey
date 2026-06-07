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
        return [_view];
    }

    //! Garmin Connect app-settings changed (beta/store installs): re-apply them.
    //! This is the sole configuration path (see AnalogView.applyProperties).
    function onSettingsChanged() as Void {
        if (_view != null) {
            _view.applyProperties();
        }
        WatchUi.requestUpdate();
    }
}
