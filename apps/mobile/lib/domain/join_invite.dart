/// The six-digit ride code is brute-forceable over the public internet on
/// its own, so anything shared as text (rather than spoken/typed) also
/// carries the high-entropy join token. `#` never appears in a six-digit
/// code or in [_tokenPattern]'s alphabet, so the two can always be told
/// apart unambiguously.
const _codePattern = r'\d{6}';
const _tokenPattern = r'[A-Za-z0-9]{16,128}';

String joinInviteText(String rideCode, String joinToken) =>
    '$rideCode#$joinToken';

/// Extracts a ride code and, if present, its paired join token from
/// arbitrary pasted text - a bare code, a `code#token` invite, or a full
/// shared sentence containing either one.
({String? code, String? token}) parseJoinInvite(String pastedText) {
  final compound = RegExp(
    '($_codePattern)#($_tokenPattern)',
  ).firstMatch(pastedText);
  if (compound != null) {
    return (code: compound.group(1), token: compound.group(2));
  }
  final bareCode = RegExp(r'\b\d{6}\b').firstMatch(pastedText);
  return (code: bareCode?.group(0), token: null);
}
