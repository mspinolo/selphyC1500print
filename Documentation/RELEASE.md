# Rilascio dell'app

`scripts/make-app.sh` costruisce `SELPHY CP1500 Print.app` dall'eseguibile SwiftPM:
Info.plist e entitlements stanno in `Packaging/`.

## Sandbox e permessi
L'app è in sandbox (`com.apple.security.app-sandbox`) e accede solo ai file scelti
dall'utente (`files.user-selected.read-write`). Profilo ICC e cartella di salvataggio
sono ricordati con bookmark security-scoped, per questo serve anche
`files.bookmarks.app-scope`. Non ci sono permessi di rete.

## Firma
- La CI firma **ad-hoc** (`codesign --sign -`): l'app si avvia sul Mac che l'ha
  costruita; su un altro Mac Gatekeeper la blocca finché non si usa clic destro →
  Apri (o `xattr -dr com.apple.quarantine`).
- Per distribuirla serve un **Developer ID Application** (account Apple Developer del
  proprietario): `SIGN_IDENTITY="Developer ID Application: …" scripts/make-app.sh`,
  poi notarizzazione con `xcrun notarytool submit … --wait` e `xcrun stapler staple`.
  Questi passi non sono automatizzati finché non esistono le credenziali.

## Non ancora presente
- Icona dell'app.
- Lingua: l'interfaccia è solo in italiano (decisione del proprietario); la
  localizzazione è rimandata.
