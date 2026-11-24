from app.main import app


def test_media_transit_lives_where_the_app_calls_it():
    routes = {(r.path, m) for r in app.routes for m in (getattr(r, 'methods', None) or ())}
    assert ('/api/v1/business/media-transit', 'POST') in routes
    assert ('/api/v1/business/media-transit', 'GET') in routes
    assert ('/api/v1/business/media-transit/ack', 'POST') in routes
    # Never mounted on the API root again (that answered 404 to the app).
    assert ('/api/v1', 'POST') not in routes
