// Card maps exactly as App.Cards builds them (server/lib/app/cards.ex), generated
// from realistic tool results pinned to Sat Oct 10 2026, 2:00 PM America/Chicago.
// The goldens render these verbatim, so they are the wire shape, not a guess at it.

const Map<String, dynamic> weatherCard = {
  'type': 'weather',
  'condition': 'Partly cloudy',
  'daily': [
    {
      'condition': 'Rain',
      'hi': '74°',
      'icon': 'rain',
      'label': 'Sun',
      'lo': '58°',
      'precip': '80%',
    },
    {
      'condition': 'Thunderstorms',
      'hi': '71°',
      'icon': 'storm',
      'label': 'Mon',
      'lo': '55°',
      'precip': '60%',
    },
    {
      'condition': 'Overcast',
      'hi': '66°',
      'icon': 'wind',
      'label': 'Tue',
      'lo': '50°',
    },
    {
      'condition': 'Clear',
      'hi': '68°',
      'icon': 'clear',
      'label': 'Wed',
      'lo': '47°',
    },
    {
      'condition': 'Snow',
      'hi': '41°',
      'icon': 'snow',
      'label': 'Thu',
      'lo': '30°',
      'precip': '40%',
    },
  ],
  'details': [
    {
      'label': 'Feels like',
      'value': '69°',
    },
    {
      'label': 'Wind',
      'value': '8 mph S',
    },
    {
      'label': 'Rain',
      'value': '35%',
    },
  ],
  'hi': '78°',
  'hourly': [
    {
      'condition': 'Partly cloudy',
      'icon': 'partly',
      'label': '2PM',
      'temp': '72°',
    },
    {
      'condition': 'Partly cloudy',
      'icon': 'partly',
      'label': '3PM',
      'temp': '72°',
    },
    {
      'condition': 'Overcast',
      'icon': 'cloudy',
      'label': '4PM',
      'precip': '25%',
      'temp': '71°',
    },
    {
      'condition': 'Rain',
      'icon': 'rain',
      'label': '5PM',
      'precip': '60%',
      'temp': '69°',
    },
    {
      'condition': 'Thunderstorms',
      'icon': 'storm',
      'label': '6PM',
      'precip': '70%',
      'temp': '66°',
    },
    {
      'condition': 'Partly cloudy',
      'icon': 'partly_night',
      'label': '7PM',
      'temp': '64°',
    },
  ],
  'icon': 'partly',
  'lo': '61°',
  'location': 'Belleville, IL',
  'temp': '72°',
};

const Map<String, dynamic> agendaCard = {
  'type': 'agenda',
  'events': [
    {
      'account': 'Personal',
      'time': 'All day',
      'title': "Tanya's birthday",
    },
    {
      'account': 'Personal',
      'location': 'Downtown Square',
      'time': '8:30 AM',
      'title': 'Farmers market',
    },
    {
      'account': 'Personal',
      'location': 'Westhaven Park',
      'time': '5:30 PM',
      'title': 'Soccer practice — Ellie',
    },
    {
      'account': 'Work',
      'location': 'Copper Pot',
      'time': '6:30 PM',
      'title': 'Dinner with the Hales',
    },
  ],
  'subtitle': 'Sat, Oct 10',
  'title': 'Today',
};

const Map<String, dynamic> agendaWeekCard = {
  'type': 'agenda',
  'events': [
    {
      'day': 'Today',
      'time': '8:30 AM',
      'title': 'Farmers market',
    },
    {
      'day': 'Today',
      'time': '5:30 PM',
      'title': 'Soccer practice',
    },
    {
      'day': 'Tomorrow',
      'time': '11:00 AM',
      'title': "Brunch at Mom's",
    },
    {
      'day': 'Mon, Oct 12',
      'location': 'Bright Smiles Dental',
      'time': '9:15 AM',
      'title': 'Dentist — David',
    },
    {
      'day': 'Mon, Oct 12',
      'time': '2:00 PM',
      'title': 'Quarterly planning',
    },
    {
      'day': 'Tue, Oct 13',
      'time': '6:30 PM',
      'title': 'PTA meeting',
    },
  ],
  'more': '+2 more',
  'title': 'This week',
};

const Map<String, dynamic> listCard = {
  'type': 'list',
  'items': [
    {
      'done': false,
      'text': 'milk',
    },
    {
      'done': false,
      'text': 'butter',
    },
    {
      'done': false,
      'text': 'sourdough loaf',
    },
    {
      'done': false,
      'text': 'chicken thighs',
    },
    {
      'done': false,
      'text': 'parmesan',
    },
    {
      'done': false,
      'text': 'lemons',
    },
    {
      'done': true,
      'text': 'eggs',
    },
  ],
  'more': '+2 more',
  'scope': 'Household',
  'summary': '6 left · 3 done',
  'title': 'Groceries',
};

const Map<String, dynamic> remindersCard = {
  'type': 'reminders',
  'items': [
    {
      'cadence': 'every Sat',
      'tag': 'Household',
      'text': 'Take out the trash',
      'when': 'Today, 7:30 PM',
    },
    {
      'text': 'Call mom',
      'when': 'Tomorrow, 9:00 AM',
    },
    {
      'tag': 'Follow-up',
      'text': 'Check whether Bob replied about the contract',
      'when': 'Wed, 10:00 AM',
    },
    {
      'cadence': 'every 3 days',
      'text': 'Water the ferns',
      'when': 'Mon, 8:00 AM',
    },
  ],
  'title': 'Reminders',
};

const Map<String, dynamic> emailCard = {
  'type': 'email',
  'more': '+1 more',
  'rows': [
    {
      'account': 'Personal',
      'from': 'Alice Smith',
      'subject': 'Lunch Tuesday?',
      'when': '1:05 PM',
    },
    {
      'account': 'Personal',
      'from': 'Ameren Illinois',
      'subject': 'Your October statement is ready',
      'when': 'Yesterday',
    },
    {
      'account': 'Personal',
      'from': 'Coach Ramirez',
      'subject': "Saturday's game moved to 9am",
      'when': 'Thu',
    },
    {
      'account': 'Work',
      'from': 'GitHub',
      'subject': '[orbital] 3 new issues',
      'when': 'Tue',
    },
    {
      'account': 'Work',
      'from': 'Priya Natarajan',
      'subject': 'Re: Q4 roadmap',
      'when': 'Sep 24',
    },
  ],
  'title': 'Unread',
};
