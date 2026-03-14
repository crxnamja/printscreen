const supabase = require('./db');
const { sendSMS } = require('./twilio');

async function checkAndReveal(dailyPromptId) {
  // Get all responses for this daily prompt
  const { data: responses } = await supabase
    .from('responses')
    .select('*, users(*)')
    .eq('daily_prompt_id', dailyPromptId);

  if (!responses || responses.length < 2) return false;

  // Check if reveal already sent
  const { data: dp } = await supabase
    .from('daily_prompts')
    .select('reveal_sent_at, prompts(text)')
    .eq('id', dailyPromptId)
    .single();

  if (dp.reveal_sent_at) return false;

  // Send each person their partner's answer
  for (const response of responses) {
    const partner = responses.find((r) => r.user_id !== response.user_id);
    if (!partner) continue;

    let revealText = `💌 The reveal!\n\nYou said: "${response.body || '(photo)'}"\n\n${partner.users.name} said: "${partner.body || '(photo)'}"`;

    // Send partner's media if they sent a photo
    await sendSMS(response.users.phone, revealText, partner.media_url);
  }

  // Mark reveal as sent
  await supabase
    .from('daily_prompts')
    .update({ reveal_sent_at: new Date().toISOString() })
    .eq('id', dailyPromptId);

  console.log('Reveal sent!');
  return true;
}

module.exports = { checkAndReveal };
