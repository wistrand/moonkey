import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class MoonkeyApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new AnalogView();
        // Pair a watch-face delegate so the native editor's accent-colour edits
        // preview live (devices with the watch-face editor); harmless elsewhere.
        if (WatchUi has :WatchFaceDelegate) {
            return [view, new AnalogWatchFaceDelegate(view)];
        }
        return [view];
    }
}
