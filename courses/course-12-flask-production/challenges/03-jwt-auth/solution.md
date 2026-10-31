# Solution — JWT Login and Protected Routes

One file to edit: `app.py`. The complete implementation:

```python
from flask import Flask, jsonify, request
import jwt
import datetime

_USERS = {'admin': 'secret'}


def create_app(test_config=None):
    app = Flask(__name__)
    app.config['SECRET_KEY'] = 'dev-secret-change-in-production'
    if test_config:
        app.config.update(test_config)

    @app.route('/login', methods=['POST'])
    def login():
        data = request.get_json(silent=True) or {}
        username = data.get('username', '')
        password = data.get('password', '')
        if _USERS.get(username) != password:
            return jsonify({'error': 'Invalid credentials'}), 401
        token = jwt.encode(
            {
                'sub': username,
                'exp': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1),
            },
            app.config['SECRET_KEY'],
            algorithm='HS256',
        )
        return jsonify({'token': token})

    @app.route('/protected')
    def protected():
        auth = request.headers.get('Authorization', '')
        if not auth.startswith('Bearer '):
            return jsonify({'error': 'Missing or malformed Authorization header'}), 401
        token = auth.split(' ', 1)[1]
        try:
            payload = jwt.decode(token, app.config['SECRET_KEY'], algorithms=['HS256'])
        except jwt.PyJWTError:
            return jsonify({'error': 'Invalid or expired token'}), 401
        return jsonify({'message': f'Hello, {payload["sub"]}!'})

    return app
```

## Why each piece is required

**`algorithms=['HS256']` is a list, not a string.** PyJWT enforces this to block the algorithm-confusion attack: a malicious JWT can set `"alg": "none"` in its header. A server that passes `algorithm='none'` (or a string that gets mishandled) would accept a token with no signature at all. An explicit allowlist means only HS256-signed tokens are accepted regardless of what the header claims.

**`except jwt.PyJWTError`** is the base class for every PyJWT failure: `DecodeError`, `ExpiredSignatureError`, `InvalidSignatureError`, and others all inherit from it. Catching the base class gives you one handler for all error paths. Never catch `Exception` here — a bug inside your route logic (e.g. a `KeyError` on the payload) would be silently swallowed and returned as a 401.

**`auth.split(' ', 1)[1]`** — the `1` limits the split so a token that somehow contains a space doesn't get truncated. Without the limit, `split(' ')` on `"Bearer a b"` returns `['Bearer', 'a', 'b']` and `[1]` is `'a'`, not the full token.

**`datetime.timezone.utc` vs `datetime.datetime.utcnow()`**. `utcnow()` returns a naive datetime (no timezone info). PyJWT 2.x compares expiry against an aware UTC timestamp, so a naive `exp` can cause `DecodeError` on some versions. `datetime.now(datetime.timezone.utc)` returns an aware datetime and is the correct form going forward.

## Security angle

The JWT payload is base64-encoded, not encrypted. Anyone with the token can decode the payload and read the `sub` claim. Never put secrets, passwords, or PII in a JWT — only put identifiers that are safe to expose to the token's holder. If you need the payload to be unreadable, you want JWE (JSON Web Encryption), not JWS (what HS256 provides).

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-jwt-auth
# replace app.py with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-12-flask-production/challenges/03-jwt-auth/verify.sh
```
