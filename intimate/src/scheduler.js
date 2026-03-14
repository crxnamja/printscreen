const cron = require('node-cron');
const supabase = require('./db');
const { sendSMS } = require('./twilio');

async function pickUnusedPrompt() {
  // Get prompt IDs used in the last 30 days
  const thirtyDaysAgo = new Date();
  thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);

  const { data: recent } = await supabase
    .from('daily_prompts')
    .select('prompt_id')
    .gte('date', thirtyDaysAgo.toISOString().split('T')[0]);

  const usedIds = (recent || []).map((r) => r.prompt_id);

  // Pick a random active prompt not recently used
  let query = supabase.from('prompts').select('*').eq('active', true);
  if (usedIds.length > 0) {
    query = query.not('id', 'in', `(${usedIds.join(',')})`);
  }

  const { data: available } = await query;

  // If all prompts used recently, pick from all active prompts
  const pool = available && available.length > 0 ? available : (await supabase.from('prompts').select('*').eq('active', true)).data;

  if (!pool || pool.length === 0) {
    console.error('No prompts available!');
    return null;
  }

  return pool[Math.floor(Math.random() * pool.length)];
}

async function scheduleDailyPrompt() {
  const today = new Date().toISOString().split('T')[0];

  // Check if already scheduled today
  const { data: existing } = await supabase
    .from('daily_prompts')
    .select('id')
    .eq('date', today)
    .limit(1);

  if (existing && existing.length > 0) {
    console.log('Already scheduled for today.');
    return;
  }

  const prompt = await pickUnusedPrompt();
  if (!prompt) return;

  // Random time between 9 AM and 8 PM local
  const hour = 9 + Math.floor(Math.random() * 11);
  const minute = Math.floor(Math.random() * 60);

  const scheduledAt = new Date();
  scheduledAt.setHours(hour, minute, 0, 0);

  // If the random time already passed today, send within the next 5 minutes
  if (scheduledAt <= new Date()) {
    const now = new Date();
    scheduledAt.setHours(now.getHours(), now.getMinutes() + 5, 0, 0);
  }

  const { error } = await supabase.from('daily_prompts').insert({
    prompt_id: prompt.id,
    scheduled_at: scheduledAt.toISOString(),
    date: today,
  });

  if (error) {
    console.error('Failed to schedule:', error.message);
    return;
  }

  console.log(`Scheduled prompt #${prompt.id} for ${scheduledAt.toLocaleTimeString()}`);
}

async function checkAndSend() {
  const { data } = await supabase
    .from('daily_prompts')
    .select('*, prompts(*)')
    .lte('scheduled_at', new Date().toISOString())
    .is('sent_at', null)
    .limit(1);

  if (!data || data.length === 0) return;

  const dailyPrompt = data[0];
  const promptText = dailyPrompt.prompts.text;

  // Get both users
  const { data: users } = await supabase.from('users').select('*');
  if (!users || users.length < 2) {
    console.error('Need 2 users in the database.');
    return;
  }

  const message = `💌 Intimate\n\n${promptText}`;

  for (const user of users) {
    await sendSMS(user.phone, message, dailyPrompt.prompts.mms_url);
    console.log(`Sent to ${user.name}`);
  }

  await supabase
    .from('daily_prompts')
    .update({ sent_at: new Date().toISOString() })
    .eq('id', dailyPrompt.id);
}

function startScheduler() {
  // Schedule daily prompt at midnight
  cron.schedule('0 0 * * *', () => {
    console.log('Midnight: scheduling today\'s prompt...');
    scheduleDailyPrompt();
  });

  // Check every minute if it's time to send
  cron.schedule('* * * * *', () => {
    checkAndSend();
  });

  // Also schedule on startup (in case server restarted after midnight)
  scheduleDailyPrompt();

  console.log('Scheduler started.');
}

module.exports = { startScheduler, scheduleDailyPrompt, checkAndSend };
