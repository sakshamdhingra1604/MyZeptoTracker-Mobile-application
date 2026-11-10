const String defaultApiBase = 'http://192.168.1.13:8765';
const String defaultApiKey = 'myzeptotracker-secret-2024';
const String stockChannelId = 'myzeptotracker_stock_alerts';

/// Default product list (mirrors backend/config/products.json).
const List<Map<String, dynamic>> kDefaultProducts = [
  {
    'id': 'iphone17_256',
    'name': 'iPhone 17 256GB (Any Colour)',
    'category': 'Phones',
    'query': 'iPhone 17 256GB',
    'search_url': 'https://www.zeptonow.com/search?query=iPhone%2017%20256GB',
    'enabled': true,
    'match': {'storage': '256GB', 'model': 'iPhone 17'},
  },
  {
    'id': 'ps5_any',
    'name': 'PlayStation 5 (Any Edition)',
    'category': 'Gaming',
    'query': 'PlayStation 5 PS5',
    'search_url': 'https://www.zeptonow.com/search?query=PlayStation%205%20PS5',
    'enabled': true,
    'match': {'model': 'PlayStation 5', 'edition': 'any'},
  },
  {
    'id': 'kinder_joy_regular',
    'name': 'Kinder Joy (Regular)',
    'category': 'Snacks',
    'query': 'Kinder Joy',
    'search_url': 'https://www.zeptonow.com/search?query=Kinder%20Joy',
    'enabled': true,
    'match': {'edition': 'regular'},
  },
  {
    'id': 'kinder_joy_special',
    'name': 'Kinder Joy (Special / Limited Edition)',
    'category': 'Snacks',
    'query': 'Kinder Joy special edition',
    'search_url':
        'https://www.zeptonow.com/search?query=Kinder%20Joy%20special%20edition',
    'enabled': true,
    'match': {'edition': 'special'},
  },
];

/// Remove trailing slashes from a URL base.
String normaliseBase(String value) =>
    value.trim().replaceFirst(RegExp(r'/+$'), '');
