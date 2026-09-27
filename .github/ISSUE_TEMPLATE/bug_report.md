name: Bug report / Hata bildirimi

Lütfen kısa tutun ve aşağıdakileri doldurun. Türkçe veya İngilizce yazabilirsiniz.

## Ne oldu
<!-- Kısa açıklama -->

## Nasıl yeniden üretilir
1.
2.
3.

## Beklenen davranış
<!-- Normalde ne olmalıydı -->

## Ortam
- Windows sürümü:
- PowerShell sürümü (`$PSVersionTable.PSVersion`):
- Rol: `host` / `client` / `panel`
- Kurulum: `install\Install-Host.ps1` / `Install-Client.ps1` / elle
- Ağ onarımı için ayrı görevler kurulu mu (`RemoteHostRepair`, `RemoteHostRepairWatch`):

## Günlük / teşhis çıktısı
<!-- Teşhis raporu: panel > Ayarlar > Teşhis raporu üret  veya  powershell -File host\Collect-Diagnostics.ps1 -->

```
(buraya yapıştırın; gizli değerleri (token, chat id, heartbeat adresi) temizleyin)
```

## Kontrol listesi
- [ ] `tests\Test-All.ps1` ve `tests\Test-UI.ps1` hatasız çalışıyor
- [ ] Depoya gizli değer eklemedim
