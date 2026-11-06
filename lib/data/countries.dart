/// The countries a person can pick when they complete their profile. The English name is what is saved in `profiles.location` (the panel and
/// the staff forms already treat that column as the country), so these names are plain English and are not translated.
const List<String> kCountries = [
  'Afghanistan', 'Albania', 'Algeria', 'Andorra', 'Angola', 'Antigua and Barbuda', 'Argentina', 'Armenia', 'Australia', 'Austria',
  'Azerbaijan', 'Bahamas', 'Bahrain', 'Bangladesh', 'Barbados', 'Belarus', 'Belgium', 'Belize', 'Benin', 'Bhutan',
  'Bolivia', 'Bosnia and Herzegovina', 'Botswana', 'Brazil', 'Brunei', 'Bulgaria', 'Burkina Faso', 'Burundi', 'Cabo Verde', 'Cambodia',
  'Cameroon', 'Canada', 'Central African Republic', 'Chad', 'Chile', 'China', 'Colombia', 'Comoros', 'Congo', 'Costa Rica',
  "Côte d'Ivoire", 'Croatia', 'Cuba', 'Cyprus', 'Czechia', 'Democratic Republic of the Congo', 'Denmark', 'Djibouti', 'Dominica', 'Dominican Republic',
  'Ecuador', 'Egypt', 'El Salvador', 'Equatorial Guinea', 'Eritrea', 'Estonia', 'Eswatini', 'Ethiopia', 'Fiji', 'Finland',
  'France', 'Gabon', 'Gambia', 'Georgia', 'Germany', 'Ghana', 'Greece', 'Grenada', 'Guatemala', 'Guinea',
  'Guinea-Bissau', 'Guyana', 'Haiti', 'Honduras', 'Hong Kong', 'Hungary', 'Iceland', 'India', 'Indonesia', 'Iran',
  'Iraq', 'Ireland', 'Israel', 'Italy', 'Jamaica', 'Japan', 'Jordan', 'Kazakhstan', 'Kenya', 'Kiribati',
  'Kuwait', 'Kyrgyzstan', 'Laos', 'Latvia', 'Lebanon', 'Lesotho', 'Liberia', 'Libya', 'Liechtenstein', 'Lithuania',
  'Luxembourg', 'Macau', 'Madagascar', 'Malawi', 'Malaysia', 'Maldives', 'Mali', 'Malta', 'Marshall Islands', 'Mauritania',
  'Mauritius', 'Mexico', 'Micronesia', 'Moldova', 'Monaco', 'Mongolia', 'Montenegro', 'Morocco', 'Mozambique', 'Myanmar',
  'Namibia', 'Nauru', 'Nepal', 'Netherlands', 'New Zealand', 'Nicaragua', 'Niger', 'Nigeria', 'North Korea', 'North Macedonia',
  'Norway', 'Oman', 'Pakistan', 'Palau', 'Palestine', 'Panama', 'Papua New Guinea', 'Paraguay', 'Peru', 'Philippines',
  'Poland', 'Portugal', 'Puerto Rico', 'Qatar', 'Romania', 'Russia', 'Rwanda', 'Saint Kitts and Nevis', 'Saint Lucia', 'Saint Vincent and the Grenadines',
  'Samoa', 'San Marino', 'Sao Tome and Principe', 'Saudi Arabia', 'Senegal', 'Serbia', 'Seychelles', 'Sierra Leone', 'Singapore', 'Slovakia',
  'Slovenia', 'Solomon Islands', 'Somalia', 'South Africa', 'South Korea', 'South Sudan', 'Spain', 'Sri Lanka', 'Sudan', 'Suriname',
  'Sweden', 'Switzerland', 'Syria', 'Taiwan', 'Tajikistan', 'Tanzania', 'Thailand', 'Timor-Leste', 'Togo', 'Tonga',
  'Trinidad and Tobago', 'Tunisia', 'Turkey', 'Turkmenistan', 'Tuvalu', 'Uganda', 'Ukraine', 'United Arab Emirates', 'United Kingdom', 'United States',
  'Uruguay', 'Uzbekistan', 'Vanuatu', 'Vatican City', 'Venezuela', 'Vietnam', 'Yemen', 'Zambia', 'Zimbabwe',
];

/// The countries whose English name contains [query] (case-insensitive), in list order. An empty query returns them all.
List<String> searchCountries(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return kCountries;
  return [for (final c in kCountries) if (c.toLowerCase().contains(q)) c];
}

/// ISO 3166-1 alpha-2 code of each country in [kCountries], by the same English name. A flag is made from it (see [flagOfCountry]).
const Map<String, String> kCountryCodes = {
  'Afghanistan': 'AF', 'Albania': 'AL', 'Algeria': 'DZ', 'Andorra': 'AD',
  'Angola': 'AO', 'Antigua and Barbuda': 'AG', 'Argentina': 'AR', 'Armenia': 'AM',
  'Australia': 'AU', 'Austria': 'AT', 'Azerbaijan': 'AZ', 'Bahamas': 'BS',
  'Bahrain': 'BH', 'Bangladesh': 'BD', 'Barbados': 'BB', 'Belarus': 'BY',
  'Belgium': 'BE', 'Belize': 'BZ', 'Benin': 'BJ', 'Bhutan': 'BT',
  'Bolivia': 'BO', 'Bosnia and Herzegovina': 'BA', 'Botswana': 'BW', 'Brazil': 'BR',
  'Brunei': 'BN', 'Bulgaria': 'BG', 'Burkina Faso': 'BF', 'Burundi': 'BI',
  'Cabo Verde': 'CV', 'Cambodia': 'KH', 'Cameroon': 'CM', 'Canada': 'CA',
  'Central African Republic': 'CF', 'Chad': 'TD', 'Chile': 'CL', 'China': 'CN',
  'Colombia': 'CO', 'Comoros': 'KM', 'Congo': 'CG', 'Costa Rica': 'CR',
  "Côte d'Ivoire": 'CI', 'Croatia': 'HR', 'Cuba': 'CU', 'Cyprus': 'CY',
  'Czechia': 'CZ', 'Democratic Republic of the Congo': 'CD', 'Denmark': 'DK', 'Djibouti': 'DJ',
  'Dominica': 'DM', 'Dominican Republic': 'DO', 'Ecuador': 'EC', 'Egypt': 'EG',
  'El Salvador': 'SV', 'Equatorial Guinea': 'GQ', 'Eritrea': 'ER', 'Estonia': 'EE',
  'Eswatini': 'SZ', 'Ethiopia': 'ET', 'Fiji': 'FJ', 'Finland': 'FI',
  'France': 'FR', 'Gabon': 'GA', 'Gambia': 'GM', 'Georgia': 'GE',
  'Germany': 'DE', 'Ghana': 'GH', 'Greece': 'GR', 'Grenada': 'GD',
  'Guatemala': 'GT', 'Guinea': 'GN', 'Guinea-Bissau': 'GW', 'Guyana': 'GY',
  'Haiti': 'HT', 'Honduras': 'HN', 'Hong Kong': 'HK', 'Hungary': 'HU',
  'Iceland': 'IS', 'India': 'IN', 'Indonesia': 'ID', 'Iran': 'IR',
  'Iraq': 'IQ', 'Ireland': 'IE', 'Israel': 'IL', 'Italy': 'IT',
  'Jamaica': 'JM', 'Japan': 'JP', 'Jordan': 'JO', 'Kazakhstan': 'KZ',
  'Kenya': 'KE', 'Kiribati': 'KI', 'Kuwait': 'KW', 'Kyrgyzstan': 'KG',
  'Laos': 'LA', 'Latvia': 'LV', 'Lebanon': 'LB', 'Lesotho': 'LS',
  'Liberia': 'LR', 'Libya': 'LY', 'Liechtenstein': 'LI', 'Lithuania': 'LT',
  'Luxembourg': 'LU', 'Macau': 'MO', 'Madagascar': 'MG', 'Malawi': 'MW',
  'Malaysia': 'MY', 'Maldives': 'MV', 'Mali': 'ML', 'Malta': 'MT',
  'Marshall Islands': 'MH', 'Mauritania': 'MR', 'Mauritius': 'MU', 'Mexico': 'MX',
  'Micronesia': 'FM', 'Moldova': 'MD', 'Monaco': 'MC', 'Mongolia': 'MN',
  'Montenegro': 'ME', 'Morocco': 'MA', 'Mozambique': 'MZ', 'Myanmar': 'MM',
  'Namibia': 'NA', 'Nauru': 'NR', 'Nepal': 'NP', 'Netherlands': 'NL',
  'New Zealand': 'NZ', 'Nicaragua': 'NI', 'Niger': 'NE', 'Nigeria': 'NG',
  'North Korea': 'KP', 'North Macedonia': 'MK', 'Norway': 'NO', 'Oman': 'OM',
  'Pakistan': 'PK', 'Palau': 'PW', 'Palestine': 'PS', 'Panama': 'PA',
  'Papua New Guinea': 'PG', 'Paraguay': 'PY', 'Peru': 'PE', 'Philippines': 'PH',
  'Poland': 'PL', 'Portugal': 'PT', 'Puerto Rico': 'PR', 'Qatar': 'QA',
  'Romania': 'RO', 'Russia': 'RU', 'Rwanda': 'RW', 'Saint Kitts and Nevis': 'KN',
  'Saint Lucia': 'LC', 'Saint Vincent and the Grenadines': 'VC', 'Samoa': 'WS', 'San Marino': 'SM',
  'Sao Tome and Principe': 'ST', 'Saudi Arabia': 'SA', 'Senegal': 'SN', 'Serbia': 'RS',
  'Seychelles': 'SC', 'Sierra Leone': 'SL', 'Singapore': 'SG', 'Slovakia': 'SK',
  'Slovenia': 'SI', 'Solomon Islands': 'SB', 'Somalia': 'SO', 'South Africa': 'ZA',
  'South Korea': 'KR', 'South Sudan': 'SS', 'Spain': 'ES', 'Sri Lanka': 'LK',
  'Sudan': 'SD', 'Suriname': 'SR', 'Sweden': 'SE', 'Switzerland': 'CH',
  'Syria': 'SY', 'Taiwan': 'TW', 'Tajikistan': 'TJ', 'Tanzania': 'TZ',
  'Thailand': 'TH', 'Timor-Leste': 'TL', 'Togo': 'TG', 'Tonga': 'TO',
  'Trinidad and Tobago': 'TT', 'Tunisia': 'TN', 'Turkey': 'TR', 'Turkmenistan': 'TM',
  'Tuvalu': 'TV', 'Uganda': 'UG', 'Ukraine': 'UA', 'United Arab Emirates': 'AE',
  'United Kingdom': 'GB', 'United States': 'US', 'Uruguay': 'UY', 'Uzbekistan': 'UZ',
  'Vanuatu': 'VU', 'Vatican City': 'VA', 'Venezuela': 'VE', 'Vietnam': 'VN',
  'Yemen': 'YE', 'Zambia': 'ZM', 'Zimbabwe': 'ZW',
};

/// The flag emoji for a country's two-letter code (A-Z): each letter becomes its "regional indicator" symbol and the pair draws as the flag. Null for anything that is not two letters.
String? flagOfCode(String? code) {
  final c = code?.trim().toUpperCase();
  if (c == null || c.length != 2) return null;
  final a = c.codeUnitAt(0), b = c.codeUnitAt(1);
  if (a < 0x41 || a > 0x5A || b < 0x41 || b > 0x5A) return null;
  return String.fromCharCodes([0x1F1E6 + a - 0x41, 0x1F1E6 + b - 0x41]);
}

/// The flag of the country named [name] (the English name saved in `profiles.location`; capitals and spaces around it do not matter). Null when the text is empty or is not
/// one of the countries in [kCountries], for example a city someone once typed: nothing is guessed.
String? flagOfCountry(String? name) {
  final n = name?.trim().toLowerCase();
  if (n == null || n.isEmpty) return null;
  final code = _codeByLowerName[n];
  return flagOfCode(code);
}

final Map<String, String> _codeByLowerName = {for (final e in kCountryCodes.entries) e.key.toLowerCase(): e.value};
