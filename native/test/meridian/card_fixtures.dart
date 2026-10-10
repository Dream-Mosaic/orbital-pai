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

// Trackers and recipes, from the same pinned clock and the tools' own result builders: a
// month of headaches (10 entries, two on Mon Oct 5), a "no soda" habit with no values, a
// just-logged entry, Grandma's lasagna looked up and just saved, and cook mode on step 6 of 7
// and on step 1.

const Map<String, dynamic> trackerCard = {
  'range': 'Last 30 days',
  'recent': [
    {
      'note': 'behind the eyes',
      'value': '7',
      'when': 'Yesterday, 3:45 PM',
    },
    {
      'note': 'poor sleep',
      'value': '5',
      'when': 'Wed, 9:10 AM',
    },
    {
      'note': 'skipped lunch, coffee',
      'value': '6',
      'when': 'Mon, 6:00 PM',
    },
  ],
  'series': [
    {
      'count': 0,
      'label': 'Sep 11',
    },
    {
      'count': 1,
      'label': 'Sep 12',
      'value': 4,
    },
    {
      'count': 0,
      'label': 'Sep 13',
    },
    {
      'count': 0,
      'label': 'Sep 14',
    },
    {
      'count': 1,
      'label': 'Sep 15',
      'value': 3,
    },
    {
      'count': 0,
      'label': 'Sep 16',
    },
    {
      'count': 0,
      'label': 'Sep 17',
    },
    {
      'count': 0,
      'label': 'Sep 18',
    },
    {
      'count': 0,
      'label': 'Sep 19',
    },
    {
      'count': 0,
      'label': 'Sep 20',
    },
    {
      'count': 1,
      'label': 'Sep 21',
      'value': 5,
    },
    {
      'count': 0,
      'label': 'Sep 22',
    },
    {
      'count': 0,
      'label': 'Sep 23',
    },
    {
      'count': 0,
      'label': 'Sep 24',
    },
    {
      'count': 1,
      'label': 'Sep 25',
      'peak': '8',
      'value': 8,
    },
    {
      'count': 0,
      'label': 'Sep 26',
    },
    {
      'count': 0,
      'label': 'Sep 27',
    },
    {
      'count': 1,
      'label': 'Sep 28',
      'value': 6,
    },
    {
      'count': 0,
      'label': 'Sep 29',
    },
    {
      'count': 0,
      'label': 'Sep 30',
    },
    {
      'count': 1,
      'label': 'Oct 1',
      'value': 5,
    },
    {
      'count': 0,
      'label': 'Oct 2',
    },
    {
      'count': 0,
      'label': 'Oct 3',
    },
    {
      'count': 0,
      'label': 'Oct 4',
    },
    {
      'count': 2,
      'label': 'Oct 5',
      'value': 6,
    },
    {
      'count': 0,
      'label': 'Oct 6',
    },
    {
      'count': 1,
      'label': 'Oct 7',
      'value': 5,
    },
    {
      'count': 0,
      'label': 'Oct 8',
    },
    {
      'count': 1,
      'label': 'Oct 9',
      'value': 7,
    },
    {
      'count': 0,
      'label': 'Oct 10',
    },
  ],
  'stats': [
    {
      'label': 'Entries',
      'value': '10',
    },
    {
      'label': 'Avg',
      'value': '5.3',
    },
    {
      'label': 'Range',
      'value': '3–8',
    },
  ],
  'title': 'Headache',
  'top_tags': [
    'skipped lunch ×3',
    'poor sleep ×2',
    'screen time ×2',
  ],
  'type': 'tracker',
};

const Map<String, dynamic> trackerHabitCard = {
  'range': 'Last 30 days',
  'recent': [
    {
      'when': 'Yesterday, 9:30 PM',
    },
    {
      'when': 'Thu, 9:30 PM',
    },
    {
      'when': 'Wed, 9:30 PM',
    },
  ],
  'series': [
    {
      'count': 0,
      'label': 'Sep 11',
    },
    {
      'count': 0,
      'label': 'Sep 12',
    },
    {
      'count': 1,
      'label': 'Sep 13',
    },
    {
      'count': 1,
      'label': 'Sep 14',
    },
    {
      'count': 1,
      'label': 'Sep 15',
    },
    {
      'count': 0,
      'label': 'Sep 16',
    },
    {
      'count': 1,
      'label': 'Sep 17',
    },
    {
      'count': 1,
      'label': 'Sep 18',
    },
    {
      'count': 1,
      'label': 'Sep 19',
    },
    {
      'count': 1,
      'label': 'Sep 20',
    },
    {
      'count': 1,
      'label': 'Sep 21',
    },
    {
      'count': 1,
      'label': 'Sep 22',
    },
    {
      'count': 0,
      'label': 'Sep 23',
    },
    {
      'count': 0,
      'label': 'Sep 24',
    },
    {
      'count': 1,
      'label': 'Sep 25',
    },
    {
      'count': 1,
      'label': 'Sep 26',
    },
    {
      'count': 1,
      'label': 'Sep 27',
    },
    {
      'count': 1,
      'label': 'Sep 28',
    },
    {
      'count': 1,
      'label': 'Sep 29',
    },
    {
      'count': 1,
      'label': 'Sep 30',
    },
    {
      'count': 1,
      'label': 'Oct 1',
    },
    {
      'count': 1,
      'label': 'Oct 2',
    },
    {
      'count': 0,
      'label': 'Oct 3',
    },
    {
      'count': 1,
      'label': 'Oct 4',
    },
    {
      'count': 1,
      'label': 'Oct 5',
    },
    {
      'count': 1,
      'label': 'Oct 6',
    },
    {
      'count': 1,
      'label': 'Oct 7',
    },
    {
      'count': 1,
      'label': 'Oct 8',
    },
    {
      'count': 1,
      'label': 'Oct 9',
    },
    {
      'count': 0,
      'label': 'Oct 10',
    },
  ],
  'stats': [
    {
      'label': 'Entries',
      'value': '23',
    },
    {
      'label': 'Best streak',
      'value': '8 days',
    },
  ],
  'title': 'No soda',
  'type': 'tracker',
};

const Map<String, dynamic> trackerLoggedCard = {
  'label': 'Logged',
  'note': 'behind the eyes, came on at work',
  'summary': '12th entry',
  'tags': [
    'skipped lunch',
    'coffee',
  ],
  'title': 'Headache',
  'type': 'tracker_logged',
  'value': '6',
  'when': 'Today, 1:40 PM',
};

const Map<String, dynamic> recipeCard = {
  'ingredients': [
    {
      'item': 'ground beef',
      'qty': '1 lb',
    },
    {
      'item': 'Italian sausage',
      'qty': '1 lb',
    },
    {
      'item': 'lasagna noodles',
      'qty': '12',
    },
    {
      'item': 'marinara',
      'qty': '1 (24 oz) jar',
    },
    {
      'item': 'ricotta cheese',
      'qty': '2 cups',
    },
    {
      'item': 'large eggs',
      'qty': '2',
    },
    {
      'item': 'shredded mozzarella',
      'qty': '3 cups',
    },
    {
      'item': 'grated parmesan',
      'qty': '1 cup',
    },
    {
      'item': 'garlic, minced',
      'qty': '3 cloves',
    },
    {
      'item': 'salt',
      'qty': '½ tsp',
    },
    {
      'item': 'Fresh basil',
    },
  ],
  'ingredients_label': '11 ingredients',
  'meta': 'Serves 8 · from Grandma',
  'notes': 'Freezes well — wrap it tight and bake from frozen at 375°F for 90 minutes.',
  'steps': [
    {
      'number': '1',
      'text': 'Preheat the oven to 375°F.',
    },
    {
      'number': '2',
      'text': 'Brown the beef and sausage with the garlic, about 8 minutes; drain.',
    },
    {
      'number': '3',
      'text': 'Boil the noodles until just tender, 8 to 10 minutes.',
    },
    {
      'number': '4',
      'text': 'Stir the eggs and half the parmesan into the ricotta.',
    },
    {
      'number': '5',
      'text': 'Layer sauce, noodles, ricotta and mozzarella three times; finish with sauce and parmesan.',
    },
    {
      'number': '6',
      'text': 'Cover with foil and bake 25 minutes, then uncover and bake 20 more minutes.',
    },
    {
      'number': '7',
      'text': 'Let it rest 15 minutes before cutting.',
    },
  ],
  'steps_label': '7 steps',
  'title': "Grandma's Lasagna",
  'type': 'recipe',
};

const Map<String, dynamic> recipeSavedCard = {
  'ingredients': [
    {
      'item': 'ground beef',
      'qty': '1 lb',
    },
    {
      'item': 'Italian sausage',
      'qty': '1 lb',
    },
    {
      'item': 'lasagna noodles',
      'qty': '12',
    },
    {
      'item': 'marinara',
      'qty': '1 (24 oz) jar',
    },
    {
      'item': 'ricotta cheese',
      'qty': '2 cups',
    },
    {
      'item': 'large eggs',
      'qty': '2',
    },
    {
      'item': 'shredded mozzarella',
      'qty': '3 cups',
    },
    {
      'item': 'grated parmesan',
      'qty': '1 cup',
    },
    {
      'item': 'garlic, minced',
      'qty': '3 cloves',
    },
    {
      'item': 'salt',
      'qty': '½ tsp',
    },
    {
      'item': 'Fresh basil',
    },
  ],
  'ingredients_label': '11 ingredients',
  'meta': 'Serves 8 · from Grandma',
  'notes': 'Freezes well — wrap it tight and bake from frozen at 375°F for 90 minutes.',
  'status': 'Saved',
  'steps': [
    {
      'number': '1',
      'text': 'Preheat the oven to 375°F.',
    },
    {
      'number': '2',
      'text': 'Brown the beef and sausage with the garlic, about 8 minutes; drain.',
    },
    {
      'number': '3',
      'text': 'Boil the noodles until just tender, 8 to 10 minutes.',
    },
    {
      'number': '4',
      'text': 'Stir the eggs and half the parmesan into the ricotta.',
    },
    {
      'number': '5',
      'text': 'Layer sauce, noodles, ricotta and mozzarella three times; finish with sauce and parmesan.',
    },
    {
      'number': '6',
      'text': 'Cover with foil and bake 25 minutes, then uncover and bake 20 more minutes.',
    },
    {
      'number': '7',
      'text': 'Let it rest 15 minutes before cutting.',
    },
  ],
  'steps_label': '7 steps',
  'title': "Grandma's Lasagna",
  'type': 'recipe',
};

const Map<String, dynamic> cookStepCard = {
  'next': 'Let it rest 15 minutes…',
  'next_label': 'Next',
  'progress': 'Step 6 of 7',
  'step': 6,
  'step_count': 7,
  'text': 'Cover with foil and bake 25 minutes, then uncover and bake 20 more minutes.',
  'timers': [
    '25 minutes',
    '20 more minutes',
  ],
  'title': "Grandma's Lasagna",
  'type': 'cook_step',
};

const Map<String, dynamic> cookFirstStepCard = {
  'next': 'Brown the beef and sausage…',
  'next_label': 'Next',
  'progress': 'Step 1 of 7',
  'step': 1,
  'step_count': 7,
  'text': 'Preheat the oven to 375°F.',
  'title': "Grandma's Lasagna",
  'type': 'cook_step',
};
