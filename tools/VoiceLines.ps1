# RemoteWatchdog - SABIT anons cumleleri (tek kaynak).
# Panelin sesli anons metinleri cogu degiskendir; ancak kritik olanlar SABITtir. Internetsiz
# kadin sesi uretebilmek icin bu cumleler edge-tts ile ONCEDEN mp3'e cevrilip onbellege
# alinir (bkz. tools\Build-VoiceCache.ps1). Boylece internet gittiginde anons yine soylenir.
#
# Kural: buraya eklenen cumle, panelde konusulan cumlenin AYNEN karsiligi olmali.
# Panel bu listeyi dogrudan okur; yeni cumle eklenince yeniden onbellek uretilmelidir.

$script:VwVoiceLines = [ordered]@{
    # Host metni ikiye boler: "Ağ sorunu algılandı. Eksik: <dinamik>. Onarım başlatılıyor."
    # Esnek eslesme iki cumleyi ayri ayri yakalar; yine de kisa/tek parca varyantlari
    # onceden uretip her ihtimale karsi hazir tutuyoruz.
    'netdown'    = 'Ağ sorunu algılandı. Onarım başlatılıyor.'
    'netdown1'   = 'Ağ sorunu algılandı.'
    'netdown2'   = 'Onarım başlatılıyor.'
    'netfix'     = 'Bağlantı düzeldi.'
    'netrepair'  = 'Ağ onarılıyor.'
    'repairok'   = 'Onarım tamamlandı.'
    'repairfail' = 'Onarım başarısız oldu.'
    'repairstop' = 'Onarım iptal edildi.'
    'rebooted'   = 'Sistem yeniden başlatıldı.'
    'checkok'    = 'Denetleme bitti, her şey yolunda.'
    'checkbad'   = 'Denetleme bitti, sorun var.'
    'voiceon'    = 'Sesli anons açıldı.'
    'testses'    = 'Uzak makine bağlantısı düzeldi, her şey yolunda.'
    # Restart anonslari: metin kademeli olarak kurulur (saniye eklenir), bu yuzden sabit
    # varyantlar onceden uretilir; panel metnin basina gore en yakini secer.
    'rebootplan' = 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.'
    'reboot60'   = 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak. 60 saniye içinde.'
    'reboot30'   = 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak. 30 saniye içinde.'
    'reboot10'   = 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak. 10 saniye içinde.'
    'rebootskip' = 'Açık belgeler var, yeniden başlatma iptal edildi. Belgeleri kaydedip kapatın.'
    # Host bu metni iki bicimde yazabiliyor; ikisi de onbellekte.
    'rebootcancel'  = 'Yeniden başlatma iptal edildi, bilgisayar açık kalacak.'
    'rebootcancel2' = 'Açık belgeler var, yeniden başlatma iptal edildi. Belgeleri kaydedip kapatın.'
    # Geri sayim HATIRLATMASI farkli cumle duzeni kurar ("bilgisayar 45 saniye içinde
    # yeniden başlatılacak"); onun da hazir varyantini koyuyoruz.
    'reminder'   = 'Ağ sorunları çözülemedi, bilgisayar yeniden başlatılacak.'
    'reminder2'  = 'Ağ sorunları çözülemedi. Bilgisayar yeniden başlatılacak.'
}
