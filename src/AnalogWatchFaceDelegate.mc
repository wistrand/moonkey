import Toybox.WatchUi;
import Toybox.Application;
import Toybox.Lang;

//! Watch-face delegate. Its sole job is forwarding native-editor accent-colour
//! edits to the view so the editor preview updates live (devices with the
//! watch-face configuration editor, fenix 8+ / API 5.1.0). No-op elsewhere.
class AnalogWatchFaceDelegate extends WatchUi.WatchFaceDelegate {
    private var _view as AnalogView;

    function initialize(view as AnalogView) {
        WatchFaceDelegate.initialize();
        _view = view;
    }

    //! Called while the user edits the watch face in the native editor.
    function onWatchFaceConfigEdited(options as Lang.Dictionary) as Void {
        if (!(Application has :WatchFaceConfig)) {
            return;
        }
        var settings = Application.WatchFaceConfig.getSettings(options[:configId]);
        if (settings != null) {
            var ac = settings.accentColor;
            if (ac != null && ac.color != null) {
                _view.setAccentColor(ac.color as Number);
            }
            if (settings.styleId != null) {
                _view.setTzStyle(settings.styleId as Number);
            }
            var dcol = settings.complicationColor;
            if (dcol != null && dcol.color != null) {
                _view.setDataColor(dcol.color as Number);
            }
            var cs = settings.complicationSettings;
            if (cs != null) {
                for (var i = 0; i < cs.size(); i++) {
                    var cid = cs[i].complicationId;
                    if (cid != null) {
                        _view.setComplication(cs[i].uniqueIdentifier as Number, cid);
                    }
                }
            }
        }
    }

    //! Editor tap: select the complication at the tapped field, so the user picks
    //! one by tapping its place on the face rather than by numeric id.
    function onTap(clickEvent as WatchUi.ClickEvent) as Lang.Boolean {
        var c = clickEvent.getCoordinates();
        var slot = _view.getTappedComplication(c[0], c[1]);
        if (slot != null) {
            setSelectedComplication(slot);
            return true;
        }
        return false;
    }

    //! We draw fields ourselves (no layout drawables), so no editor preview
    //! drawable -- tap selection above is what matters.
    function getComplicationDrawable(complication) {
        return null;
    }
}
