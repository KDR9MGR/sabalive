/// Does [text] look like an email address: something, one @, a domain with a dot, no spaces. Lenient on purpose (the server decides if the account exists); it only
/// tells an email from a phone number or a username typed by mistake.
bool isEmailAddress(String text) => RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text.trim());
