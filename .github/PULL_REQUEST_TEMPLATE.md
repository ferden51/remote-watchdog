## Ne değişti
<!-- tek cümle -->

## Neden
<!-- hangi sorunu çözüyor, hangi senaryoda -->

## Testler
<!-- çıktıyı yapıştırın:
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-All.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\tests\Test-UI.ps1
-->

```
Gecti: 117 | Kaldi: 0
Gecti: 17 | Kaldi: 0
```

## Uyum / geriye dönük etki
- [ ] `lib/Contract.ps1` sözleşmesi değişmedi
- [ ] Değiştiyse `schemaVersion` yükseltildi ve geriye dönük okuma korundu
- [ ] Yeni ayar eklendiyse `lib/Settings.ps1` içinde tanımlandı
- [ ] `.ps1` dosyaları UTF-8 BOM ile kaydedildi
- [ ] Gizli değer (token/chat id/heartbeat/parola/kullanıcı adı) eklemedim
- [ ] `README.md` / `README.en.md` güncel

## İlgili konu
<!-- Closes #12 gibi -->
