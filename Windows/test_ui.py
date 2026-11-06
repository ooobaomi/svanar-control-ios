"""Hidden, local widget-construction regression; no real device or audio writes."""
import os
import tempfile
from pathlib import Path

with tempfile.TemporaryDirectory() as directory:
    os.environ['SVANAR_CONTROL_DATA_DIR']=directory
    from svanar_control import App
    app=App(data_dir=Path(directory),start_services=False)
    try:
        app.open_eq();app.open_library();app.open_extras();app.update_idletasks()
        assert len(app.store.library['profiles'])==14
        assert len(app.profile_combo['values'])==14
        assert str(app.touch_write['state'])=='disabled' and str(app.game_on['state'])=='disabled'
        app.on_ble_event({'connected':True,'features':{2:[1,1,1,0,0,0],9:[0]},'done':True})
        assert str(app.game_on['state'])=='normal' and str(app.touch_write['state'])=='disabled'
        app.on_ble_event({'connected':True,'touches':{11:(1,1,1)}})
        assert str(app.touch_write['state'])=='normal'
        app.on_ble_event({'connected':False,'message':'mock disconnect'})
        assert str(app.touch_write['state'])=='disabled' and not app.touch_map
        assert all(var.get()==0 for var in app.eq_values)
        print('PASS: hidden Tk main/EQ/library/extras construction, 14 presets, support gates, disconnect invalidation; no device writes')
    finally:
        app.close()
        import logging
        logging.shutdown()
