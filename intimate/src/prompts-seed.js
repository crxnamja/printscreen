require('dotenv').config();
const supabase = require('./db');

const prompts = [
  // Silly / Playful
  { category: 'silly', text: 'If you could only eat one food for the rest of your life, what would it be?' },
  { category: 'silly', text: "What's the worst movie we've watched together?" },
  { category: 'silly', text: 'What animal best represents me and why?' },
  { category: 'silly', text: "If we swapped lives for a day, what's the first thing you'd do as me?" },
  { category: 'silly', text: 'What would my reality TV show be called?' },
  { category: 'silly', text: "What's a weird habit of mine you secretly find endearing?" },
  { category: 'silly', text: 'If we opened a business together, what would it be?' },
  { category: 'silly', text: "What song's been stuck in your head lately?" },

  // Photo
  { category: 'photo', text: 'Send a photo of exactly what you see right now.' },
  { category: 'photo', text: 'Send the last photo you took on your phone.' },
  { category: 'photo', text: 'Send a photo of something that made you smile today.' },
  { category: 'photo', text: 'Take a selfie right now — no retakes allowed.' },
  { category: 'photo', text: "Send a photo of what you're about to eat (or last ate)." },
  { category: 'photo', text: 'Send a screenshot of your current home screen.' },

  // Song Sharing
  { category: 'song', text: 'Send a song that describes your current mood.' },
  { category: 'song', text: 'Send a song that reminds you of us.' },
  { category: 'song', text: "Send a song you've been listening to on repeat." },
  { category: 'song', text: "Send a song you think I've never heard but would love." },

  // This-or-That
  { category: 'thisorthat', text: 'Beach or mountains?' },
  { category: 'thisorthat', text: 'Cook at home tonight or go out?' },
  { category: 'thisorthat', text: 'Would you rather have a personal chef or a personal driver?' },
  { category: 'thisorthat', text: 'Morning person or night owl — honestly?' },
  { category: 'thisorthat', text: 'Road trip or fly there?' },
  { category: 'thisorthat', text: 'Would you rather never use social media again or never watch TV again?' },
  { category: 'thisorthat', text: 'Surprise party or plan-it-together party?' },

  // Recommendations
  { category: 'recommendation', text: 'What\'s a restaurant we should try this weekend? Drop a name or link.' },
  { category: 'recommendation', text: 'Recommend a show we should start watching together.' },
  { category: 'recommendation', text: "What's somewhere within 2 hours of us we should day-trip to?" },
  { category: 'recommendation', text: "What's an activity or class we should try together?" },
  { category: 'recommendation', text: 'What\'s a meal I should cook for you this week?' },
];

async function seed() {
  const { data, error } = await supabase.from('prompts').insert(prompts).select();
  if (error) {
    console.error('Seed failed:', error.message);
    process.exit(1);
  }
  console.log(`Seeded ${data.length} prompts.`);
  process.exit(0);
}

seed();
