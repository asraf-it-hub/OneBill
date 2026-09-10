import 'package:flutter_test/flutter_test.dart';
import 'package:credential_manager/credential_manager.dart';

void main() {
  test('Inspect Credentials class', () {
    final credentials = Credentials(
      passwordCredential: PasswordCredential(username: 'user@onebill.app', password: 'secretpassword'),
    );
    expect(credentials.passwordCredential?.username, 'user@onebill.app');
    expect(credentials.passwordCredential?.password, 'secretpassword');
  });
}
