from panel.core import valid_name, client_state

def test_valid_name():
    assert valid_name('client_01') == 'client_01'

def test_invalid_reserved_name():
    try:
        valid_name('server')
    except ValueError:
        pass
    else:
        raise AssertionError('reserved name accepted')

def test_quota_state():
    row={'state':'active','expires_at':None,'quota_bytes':100,'upload':40,'download':60}
    assert client_state(row)=='quota'
