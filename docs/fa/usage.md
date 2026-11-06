<div dir="rtl">

# استفاده

[بازگشت به README](../../README.fa.md) · [English](../en/usage.md)

منو با `sudo darban` باز می‌شود. سرصفحه وضعیت سرویس، آدرس، سلامت CRL، تعداد کلاینت‌ها و هر هشدار لازم را نشان می‌دهد.

## انتخاب و تأیید

تأییدها دو گزینه دارند و گزینهٔ ۱ پیش‌فرض امن است.

- `↑`/`↓` یا `1`/`2` (ارقام فارسی هم) انتخاب را جابه‌جا می‌کنند.
- `Enter` تأیید می‌کند. جابه‌جایی به‌تنهایی کاری انجام نمی‌دهد.
- `Esc` یا `Ctrl+C` لغو می‌کند.

در اسکریپت یا pipe یک خط خوانده می‌شود: `2` یا مقدار دقیق هدف، تأیید است.

## منوی اصلی

| گزینه | کار |
|---|---|
| ۱ List clients | کلاینت‌های فعال با وضعیت، انقضا و روز باقی‌مانده. باطل‌شده‌ها پنهان‌اند و با انتخاب نمایش داده می‌شوند |
| ۲ Create client | صدور گواهی و پروفایل، سپس پرسیدن روش اشتراک |
| ۳ Revoke client | ابطال دائمی، انتشار CRL تأییدشده، حذف نسخهٔ سرور، حذف لینک‌های باز و رسیدگی به نشست فعال |
| ۴ Share a profile | ساخت دوبارهٔ پروفایل با آدرس و پورت فعلی و اشتراک آن؛ [راهنمای اشتراک](sharing.md) |
| ۵ Active links | نمایش و لغو لینک‌های باز |
| ۶ Delete server copy | حذف فایل `.ovpn` از سرور؛ گواهی معتبر می‌ماند |
| ۷ Settings | hostname، پورت UDP و [تنظیمات پیشرفته](advanced.md) |
| ۸ Maintenance & diagnostics | عیب‌یابی، ترمیم CRL و Restart؛ [راهنمای نگهداری](operations.md) |
| ۹ Setup | به‌روزرسانی، برگشت، اعلان نسخهٔ جدید، درباره، حذف ابزار، حذف کامل |

## نام کلاینت

نام جدید می‌تواند حروف، رقم، `_` و `-` داشته باشد، تا ۶۴ نویسه. گواهی‌های موجود می‌توانند `.`، `@` و `+` هم داشته باشند.

نامی که گواهی معتبر دارد دوباره استفاده نمی‌شود. نام باطل‌شده بعد از کامل شدن ابطال قابل استفاده است و پروفایل‌های قدیمی مسدود می‌مانند، چون OpenVPN آن‌ها را با سریال رد می‌کند. فقط اگر برای آن نام تنظیمات `client-config-dir` وجود داشته باشد سؤال پرسیده می‌شود، چون آن تنظیمات به گواهی جدید هم می‌رسند.

## دستورها

</div>

```bash
sudo darban                # menu
sudo darban --no-clear     # menu that never clears the screen
sudo darban list           # active clients
sudo darban list --all     # including revoked clients
sudo darban status         # diagnostics checklist
sudo darban repair-crl     # publish a fresh CRL and finish a revocation
sudo darban update         # check for a release and install it
sudo darban about          # version, project address and contact
sudo darban uninstall      # remove only this tool
sudo darban remove-all     # remove this tool, OpenVPN, the CA and profiles
sudo darban version
sudo darban help
```

<div dir="rtl">

`NO_COLOR=1` رنگ‌ها را خاموش می‌کند. بیرون از locale نوع UTF-8، نمادها به ASCII تبدیل می‌شوند.

عملیات در journal ثبت می‌شوند:

</div>

```bash
sudo journalctl -t darban
```

<div dir="rtl">

## نکته‌ها

- پس از ۱۵ دقیقه بدون ورودی، برنامه بسته می‌شود.
- `Ctrl+C` عملیات جاری را لغو می‌کند. در مراحل حساس، مثل صدور گواهی یا انتشار CRL، تا پایان آن مرحله نادیده گرفته می‌شود.
- گواهی‌ها خودکار تمدید نمی‌شوند. کلاینت‌های رو به انقضا در فهرست و سرصفحه دیده می‌شوند.

</div>
