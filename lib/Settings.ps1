# RemoteWatchdog - Settings: ayar tanimlari ve yardim balonlari (panel arayuzunu otomatik ureten veri).
# Yeni ayar eklemek icin $script:Defs tablosuna bir satir ekleyin; arayuz, kaydetme ve testler otomatik calisir.
# Tipler: section | bool | enum(Options) | int | text | datetime | lines | csv | days
# Target = 'client' ise istemci config.json'a, aksi halde host config.json'a yazilir.

function Get-SettingsDefs { return @(

    @{ Sec = 'ZAMANLAMA'; Type = 'section' }
    @{ Sec = 'Zamanlama'; Key = 'IntervalMinutes'; Title = 'Kontrol aralığı (dakika)'; Type = 'int' }
    @{ Sec = 'Zamanlama'; Key = 'AlertRepeatHours'; Title = 'Aynı alarm için tekrar aralığı (saat)'; Type = 'int' }
    @{ Sec = 'Zamanlama'; Key = 'NotifyRepeatHours'; Title = 'Kullanıcı bilgilendirme tekrar aralığı (saat)'; Type = 'int' }

    @{ Sec = 'RESTART POLITIKASI'; Type = 'section' }
    @{ Sec = 'Restart'; Key = 'RestartPolicy'; Title = 'Restart politikası'; Type = 'enum'; Options = @('blackout', 'always', 'never') }
    @{ Sec = 'Restart'; Key = 'BlackoutEnabled'; Title = 'Blackout penceresi (dışında sadece bilgilendirilir)'; Type = 'bool' }
    @{ Sec = 'Restart'; Key = 'BlackoutStart'; Title = 'Blackout başlangıç saati'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'BlackoutEnd'; Title = 'Blackout bitiş saati (geceye sarar)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'BlackoutFullDays'; Title = 'Tam gün blackout (hafta sonu)'; Type = 'days' }
    @{ Sec = 'Restart'; Key = 'BlackoutNights'; Title = 'Blackout geceleri'; Type = 'days' }
    @{ Sec = 'Restart'; Key = 'RebootAfterFailedCycles'; Title = 'Kaç başarısız denemeden sonra restart'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'RebootDelaySeconds'; Title = 'Restart gecikmesi (saniye)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'MaxRestartsPerDay'; Title = '24 saatte en fazla restart (0 = sınırsız)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'RebootCooldownMinutes'; Title = 'İki restart arası bekleme (dakika)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'HealthyMinutesToReset'; Title = 'Bu kadar sağlıklı kalınca bütçe sıfırlansın (dk)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'MinUptimeMinutes'; Title = 'Minimum uptime (dk, yeni açılan makine için bekle)'; Type = 'int' }
    @{ Sec = 'Restart'; Key = 'RebootSkipIfUnregistered'; Title = 'CRD kayıtsızken restart etme'; Type = 'bool' }
    @{ Sec = 'Restart'; Key = 'ForceRestartAlways'; Title = 'DAIMA zorla kapat (saat fark etmez)'; Type = 'bool' }
    @{ Sec = 'Restart'; Key = 'ForceRestartUntil'; Title = 'Daima zorla kapat bitis zamani'; Type = 'datetime' }

    @{ Sec = 'OTOMATIK ONARIM'; Type = 'section' }
    @{ Sec = 'Onarim'; Key = 'FixNetwork'; Title = 'Ağ onarımıni uygula'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'NetMaxRepairRung'; Title = 'Ag onarim kademesi (1-5)'; Type = 'int' }
    @{ Sec = 'Onarim'; Key = 'FixRdp'; Title = 'RDP ayarlarini onar (firewall + servis)'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'FixCrd'; Title = 'CRD servisini onar'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'CrdNoConnRestartCycles'; Title = 'CRD baglantisi yoksa kac dongu sonra yeniden baslat'; Type = 'int' }
    @{ Sec = 'Onarim'; Key = 'CrdRestartAfterHours'; Title = 'CRD onleyici restart (saat, 0 = kapali)'; Type = 'int' }
    @{ Sec = 'Onarim'; Key = 'CrdSignalPorts'; Title = 'CRD sinyal portlari'; Type = 'csv' }
    @{ Sec = 'Onarim'; Key = 'FixClock'; Title = 'Saat senkronunu onar'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'ServiceAutoStart'; Title = 'Servisleri Automatic yap (acilista baslasin)'; Type = 'bool' }
    @{ Sec = 'Onarim'; Key = 'ServiceCrashRecovery'; Title = 'Servis cokerse Windows kendini yeniden bassin'; Type = 'bool' }

    @{ Sec = 'VS CODE TUNNEL'; Type = 'section' }
    @{ Sec = 'Tunnel'; Key = 'TunnelRepair'; Title = 'Tunnel yoksa yeniden baslat'; Type = 'bool' }
    @{ Sec = 'Tunnel'; Key = 'TunnelName'; Title = 'Tunnel adi'; Type = 'text' }

    @{ Sec = 'SISTEM VE BELGE KORUMA'; Type = 'section' }
    @{ Sec = 'Sistem'; Key = 'ServerMode'; Title = 'Sunucu modu (uyku/hibernasyon/adaptor gucu kapatilir)'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'DisableFastStartup'; Title = 'Fast Startup kapansın'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'DisableHibernation'; Title = 'Hibernasyonu tamamen kapat (powercfg /h off)'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'OfficeSaveBeforeReboot'; Title = 'Restart oncesi Word/Excel kaydedilsin'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'OfficeSaveTimeoutSeconds'; Title = 'Belge kaydetme bekleme suresi (sn)'; Type = 'int' }
    @{ Sec = 'Sistem'; Key = 'OfficeAbortRebootIfStillOpen'; Title = 'Uygulama kapanmazsa restart yapılmasın'; Type = 'bool' }
    @{ Sec = 'Sistem'; Key = 'OfficeAbortRebootIfUnsaved'; Title = 'kaydedilmemiş belge varsa restart yapılmasın'; Type = 'bool' }

    @{ Sec = 'BILDIRIM'; Type = 'section' }
    @{ Sec = 'Bildirim'; Key = 'TelegramToken'; Title = 'Telegram bot token'; Type = 'text' }
    @{ Sec = 'Bildirim'; Key = 'TelegramChatId'; Title = 'Telegram chat id'; Type = 'text' }
    @{ Sec = 'Bildirim'; Key = 'HeartbeatUrl'; Title = 'Healthchecks ping adresi (host için gerekli: makine açıkken kendi alarmı gidemez)'; Type = 'text' }

    @{ Sec = 'TATIL'; Type = 'section' }
    @{ Sec = 'Tatil'; Key = 'HolidayMode'; Title = 'Tatil modu (full = tam blackout)'; Type = 'enum'; Options = @('full', 'default', 'none') }
    @{ Sec = 'Tatil'; Key = 'Holidays'; Title = 'Tatiller (her satır YYYY-AA-GG)'; Type = 'lines' }
    @{ Sec = 'Tatil'; Key = 'HolidaysFile'; Title = 'Tatil dosyasi (bos birakilirsa betik yanindaki holidays.txt)'; Type = 'text' }

    @{ Sec = 'ISTEMCI (BU BİLGİSAYAR)'; Type = 'section' }
    @{ Sec = 'Istemci'; Key = 'RemoteName'; Title = 'Uzak makine adı (panelde bu ad kullanılır)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'Targets'; Title = 'Uzak hedefler (her satır ip:port)'; Type = 'lines'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'RdpFile'; Title = 'RDP dosyası (.rdp)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'BrowserUrl'; Title = 'Tarayıcı adresi (CRD)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'LaunchOnRecover'; Title = 'Bağlantı düzelince otomatik aç'; Type = 'bool'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'KeepAliveMinutes'; Title = 'Oturumu canlı tutma aralığı (dk, 0 = kapalı)'; Type = 'int'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'TelegramToken'; Title = 'Telegram bot token (istemci)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'TelegramChatId'; Title = 'Telegram chat id (istemci)'; Type = 'text'; Target = 'client' }
    @{ Sec = 'Istemci'; Key = 'HeartbeatUrl'; Title = 'Healthchecks ping adresi (istemci için genelde gerekmez: saatlerce kapalıysa yanlış alarm verir)'; Type = 'text'; Target = 'client' }

    @{ Sec = 'PANEL'; Type = 'section' }
    @{ Sec = 'Panel'; Key = 'PanelRepair'; Title = 'Panel kapanırsa watchdog yeniden başlatsın'; Type = 'bool' }
    @{ Sec = 'Panel'; Key = 'PanelScriptName'; Title = 'Panel betiği dosya adı'; Type = 'text' }

    @{ Sec = 'ISLEMLER'; Type = 'section' }
    @{ Sec = 'Islem'; Type = 'actions' }
    )
}

function Get-HelpBalloonTopics { return @(
        [pscustomobject]@{ Title = 'Ayar yardımı 1/11 - Kontrol aralığı'; Text = 'Watchdog bu aralıkla bağlantıları kontrol eder. Varsayılan 5 dakika. Uzaktaki makine için 5 dk yeterlidir; çok kısa aralık gereksiz log ve trafik üretir.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 2/11 - Restart politikası'; Text = 'blackout = sadece tanımlı saatlerde restart eder. always = her koşulda. never = hiçbir zaman otomatik restart yapmaz, yalnızca bilgilendirir. Önerilen: blackout.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 3/11 - Blackout penceresi'; Text = 'Bu saatlerde program kendi kararıyla yeniden başlatabilir. Günüp saatleri 18:00, bitiş 8:00 girilirse gece yarısına sarar. Dışındaki saatlerde zorla kapatma olmaz, sadece bilgilendirme yapılır.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 4/11 - Tam gün blackout'; Text = 'Cumartesi ve Pazar gibi günlerin tamamı. Bir günü kaldırmak için o günün düğmesini kapatın. Boş bırakılırsa hafta sonu da mesai gibi korunur.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 5/11 - Tatil modu'; Text = 'full = resmi/dini tatiller tam gün blackout olur. default = normal saat kuralı uygulanır. none = tatiller yok sayılır. Tatil listesine her satır YYYY-AA-GG biçiminde gün ekleyin.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 6/11 - Google Remote Desktop kaydı'; Text = 'CRD kartı kırmızıysa cihaz Google hesabına kayıtlı değildir. Kayıt, bağlandığınız cihazdaki eklentiden değil, kendi makinesinden yapılır: remotedesktop.google.com/headless -> "Set up remote access" ile ad ve PIN alınır, sonra istemci cihazda Machines -> + ile eklenir. Tarayıcıda açık olan Google oturumu bu kaydı oluşturmaz.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 7/11 - Devre kesici (sonsuz restart koruması)'; Text = 'Otomatik restart sonsuz döngüye girmesin diye iki koruma var: 24 saatte en fazla MaxRestartsPerDay (varsayılan 3) kez restart edilir ve iki restart arasında RebootCooldownMinutes (varsayılan 60) dakika beklenir. Sınıra ulaşılınca otomatik restart durur, ekranda ve Telegram''da uyarı gider; bu süreden sonra yeniden denenir.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 8/11 - Sunucu modu'; Text = 'Açık: uyku, hibernasyon ve Fast Startup kapatılır, ağ adaptörü uykuya girmez. Dizüstü kullanıyorsanız kapatın (kurulumda -KeepSleep). Kapalıyken bu kontrol atlanır, zorla restart baskısı oluşmaz.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 9/11 - Belge koruma'; Text = 'Word/Excel belgeleri 2 dakikada bir otomatik kaydedilir. Restart öncesi kaydedilip kapatılır. Kaydedilemeyen belge varsa restart iptal edilir. "Daima zorla kapatma" bu korumayı baypaslar.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 10/11 - Ağ onarımı'; Text = 'Ağ bozulursa sırayla DNS, DHCP, adaptör/sürücü ve winsock onarımı uygulanır. Kademe 5 gerektiğinde restart önerilir. 4. kademe adaptörü sıfırlar; uzak erişiminiz tamamen kesilebilir.' }
        [pscustomobject]@{ Title = 'Ayar yardımı 11/11 - Dış izleme (heartbeat)'; Text = 'Ping, makine kendi alarmını gönderemediği zaman için vardır. Sizin kurulumunuzda host hep açık, istemci bazen kapalı olduğu için: host ping adresi ÖNEMLİDİR - makine çöktüğünde, elektrik gittiğinde, interneti kesildiğinde veya watchdog görevi silindiğinde host size hiçbir şey bildiremez, ama dışarıdaki kontrol susar ve sizi uyarır. İstemci ping adresi çoğu durumda GEREKMEZ: istemci saatlerce kapalıysa kontrol sürekli DOWN görünür ve yanlış alarm üretir; istemcinin gerçek katkısı Telegram uyarısı ve uzak hedefe TCP probu (kopuk olduğunda bildirir), ping değil. Host un interneti kesildi mi yoksa makine mi kapandı ayrımını yapmak isterseniz üçüncü bir bakış açısı gerekir: install klasöründeki GitHub Actions dosyası, sizin makineniz kapalıyken bile dışarıdan erişim testi yapar.' }
    )
}

$script:Defs = Get-SettingsDefs