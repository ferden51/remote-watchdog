# edge_tts_win - edge-tts CLI icin Windows uyumlu giris noktasi
#
# Neden var? edge-tts 7.x, ag islemleri icin aiodns kullaniyor; aiodns Windows'ta yalnizca
# SelectorEventLoop ile calisiyor. Varsayilan ProactorEventLoop ile process su hatayi verip
# ses uretmeden oluyor: "aiodns needs a SelectorEventLoop on Windows".
# Bu dosya edge_tts import edilmeden ONCE olay dongusu politikasini degistirir, sonra CLI'yi
# aynen calistirir. DRM token'in kendisi edge-tts 7.x uretir; boylece Microsoft'un dogal Turkce
# KADIN sesi (tr-TR-EmelNeural) kullanilabilir.
#
# Kullanim (panel otomatik cagirir):
#   python edge_tts_win.py --voice tr-TR-EmelNeural --file in.txt --write-media out.mp3
import asyncio
import sys

asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())

import edge_tts.util as util  # politika ayarlanmadan SONRA import edilmeli

sys.argv = ["edge-tts"] + sys.argv[1:]
util.main()