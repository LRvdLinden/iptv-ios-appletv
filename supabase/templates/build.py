"""Maakt de Bingr-e-mailtemplates (NL voor Nederlandstalige accounts, anders EN) en templates.json voor de Supabase Management API.
Taal: user_metadata.lang ("nl", "en", ...) die de app meestuurt bij het aanmaken van het account."""
import json, pathlib, html
here = pathlib.Path(__file__).parent

def page(nl, en, button_nl, button_en, url="{{ .ConfirmationURL }}", code=False):
    def block(t, b):
        title, intro, outro = t
        action = (f'<div style="font-size:34px;font-weight:800;letter-spacing:8px;color:#fff;background:#1f1f1f;border-radius:8px;padding:18px 0;text-align:center">{{{{ .Token }}}}</div>'
                  if code else
                  f'<a href="{url}" style="display:inline-block;background:#E50914;color:#ffffff;text-decoration:none;font-weight:700;font-size:16px;padding:14px 32px;border-radius:6px">{b}</a>')
        link = "" if code else (f'<p style="margin:28px 0 0;font-size:12px;line-height:18px;color:#8c8c8c">{"Werkt de knop niet? Kopieer deze link:" if b == button_nl else "Button not working? Copy this link:"}<br>'
                                f'<a href="{url}" style="color:#b3b3b3;word-break:break-all">{url}</a></p>')
        return (f'<h1 style="margin:0 0 16px;font-size:26px;line-height:32px;font-weight:800;color:#ffffff">{title}</h1>'
                f'<p style="margin:0 0 28px;font-size:16px;line-height:24px;color:#d6d6d6">{intro}</p>{action}'
                f'<p style="margin:28px 0 0;font-size:14px;line-height:21px;color:#b3b3b3">{outro}</p>{link}')
    body_nl, body_en = block(nl, button_nl), block(en, button_en)
    foot_nl = 'Je ontvangt deze e-mail omdat iemand dit adres ({{ .Email }}) bij Bingr heeft gebruikt. Was jij dit niet? Dan kun je deze e-mail negeren.'
    foot_en = 'You received this email because this address ({{ .Email }}) was used with Bingr. If this wasn\'t you, you can ignore this email.'
    return f'''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark"><title>Bingr</title></head>
<body style="margin:0;padding:0;background:#000000">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#000000"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif">
<tr><td style="padding:0 4px 24px">
  <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
    <td style="vertical-align:middle"><img src="https://bingr.online/apple-touch-icon.png" width="44" height="44" alt="" style="display:block;border-radius:10px"></td>
    <td style="vertical-align:middle;padding-left:12px"><div style="font-size:30px;font-weight:900;letter-spacing:1px;color:#ffffff;line-height:30px">BINGR</div><div style="height:4px;width:74px;background:#E50914;border-radius:2px;margin-top:6px"></div></td>
  </tr></table>
</td></tr>
<tr><td style="background:#141414;border-radius:12px;padding:36px 32px;border-top:4px solid #E50914">
{{{{ if and .Data.lang (eq .Data.lang "nl") }}}}{body_nl}{{{{ else }}}}{body_en}{{{{ end }}}}
</td></tr>
<tr><td style="padding:24px 8px 0;font-size:12px;line-height:18px;color:#737373;text-align:center">
{{{{ if and .Data.lang (eq .Data.lang "nl") }}}}{foot_nl}{{{{ else }}}}{foot_en}{{{{ end }}}}<br><br>
<a href="https://bingr.online" style="color:#b3b3b3;text-decoration:none;font-weight:700">bingr.online</a> &nbsp;·&nbsp; <a href="https://bingr.online/support.html" style="color:#737373">Support</a> &nbsp;·&nbsp; <a href="https://bingr.online/privacy.html" style="color:#737373">Privacy</a>
</td></tr>
</table></td></tr></table></body></html>'''

T = {
 "confirmation": ("Welkom bij Bingr · Bevestig je e-mailadres / Confirm your email",
   ("Bevestig je e-mailadres", "Fijn dat je er bent! Bevestig je e-mailadres en log daarna in de Bingr-app in om te beginnen met kijken.", "De link is 24 uur geldig."),
   ("Confirm your email address", "Welcome to Bingr! Confirm your email address, then sign in to the Bingr app to start watching.", "This link is valid for 24 hours."),
   "E-mailadres bevestigen", "Confirm email address", False),
 "recovery": ("Bingr · Nieuw wachtwoord instellen / Reset your password",
   ("Nieuw wachtwoord instellen", "We kregen een verzoek om het wachtwoord van je Bingr-account te wijzigen. Klik op de knop om een nieuw wachtwoord te kiezen.", "Heb je dit niet aangevraagd? Dan hoef je niets te doen; je wachtwoord blijft hetzelfde."),
   ("Reset your password", "We received a request to reset the password for your Bingr account. Click the button to choose a new password.", "Didn't ask for this? You don't need to do anything; your password stays the same."),
   "Nieuw wachtwoord kiezen", "Choose a new password", False),
 "invite": ("Je bent uitgenodigd voor Bingr / You're invited to Bingr",
   ("Je bent uitgenodigd", "Je bent uitgenodigd om een Bingr-account te maken. Klik op de knop om je account te activeren en een wachtwoord te kiezen.", "De uitnodiging is 24 uur geldig."),
   ("You're invited", "You've been invited to create a Bingr account. Click the button to activate your account and choose a password.", "This invitation is valid for 24 hours."),
   "Uitnodiging accepteren", "Accept invitation", False),
 "magic_link": ("Inloggen bij Bingr / Sign in to Bingr",
   ("Inloggen bij Bingr", "Klik op de knop om in te loggen bij Bingr.", "Deze link werkt één keer en is kort geldig."),
   ("Sign in to Bingr", "Click the button to sign in to Bingr.", "This link works once and expires soon."),
   "Inloggen", "Sign in", False),
 "email_change": ("Bingr · Bevestig je nieuwe e-mailadres / Confirm your new email",
   ("Bevestig je nieuwe e-mailadres", "Je wilt het e-mailadres van je Bingr-account wijzigen naar {{ .NewEmail }}. Bevestig dit met de knop hieronder.", "Heb je dit niet aangevraagd? Wijzig dan meteen je wachtwoord."),
   ("Confirm your new email address", "You asked to change the email address of your Bingr account to {{ .NewEmail }}. Confirm with the button below.", "Didn't ask for this? Change your password right away."),
   "Nieuw adres bevestigen", "Confirm new address", False),
 "reauthentication": ("Bingr · Je verificatiecode / Your verification code",
   ("Je verificatiecode", "Gebruik deze code om te bevestigen dat jij het bent:", "De code is kort geldig. Deel hem met niemand."),
   ("Your verification code", "Use this code to confirm it's you:", "This code expires soon. Don't share it with anyone."),
   "", "", True),
}
cfg = {}
for key, (subject, nl, en, bnl, ben, code) in T.items():
    content = page(nl, en, bnl, ben, code=code)
    (here / f"{key}.html").write_text(content)
    cfg[f"mailer_subjects_{key}"] = subject
    cfg[f"mailer_templates_{key}_content"] = content
(here / "templates.json").write_text(json.dumps(cfg, ensure_ascii=False, indent=1))
print(f"{len(T)} templates")
