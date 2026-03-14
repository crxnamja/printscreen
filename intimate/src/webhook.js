const { Router } = require('express');
const supabase = require('./db');
const { sendSMS } = require('./twilio');
const { checkAndReveal } = require('./reveal');

const router = Router();

router.post('/sms', async (req, res) => {
  const from = req.body.From;
  const body = req.body.Body || '';
  const mediaUrl = req.body.MediaUrl0 || null;

  // Return empty TwiML immediately (we send responses via API)
  res.type('text/xml').send('<Response></Response>');

  try {
    // Find the user by phone number
    const { data: user } = await supabase
      .from('users')
      .select('*, partner:partner_id(name)')
      .eq('phone', from)
      .single();

    if (!user) {
      console.log(`Unknown number: ${from}`);
      return;
    }

    // Find today's daily prompt
    const today = new Date().toISOString().split('T')[0];
    const { data: dailyPrompt } = await supabase
      .from('daily_prompts')
      .select('*')
      .eq('date', today)
      .not('sent_at', 'is', null)
      .single();

    if (!dailyPrompt) {
      await sendSMS(from, "No prompt today yet — hang tight!");
      return;
    }

    // Upsert the response
    const { error } = await supabase
      .from('responses')
      .upsert(
        {
          daily_prompt_id: dailyPrompt.id,
          user_id: user.id,
          body: body.trim() || null,
          media_url: mediaUrl,
          received_at: new Date().toISOString(),
        },
        { onConflict: 'daily_prompt_id,user_id' }
      );

    if (error) {
      console.error('Failed to save response:', error.message);
      return;
    }

    console.log(`Response from ${user.name}: "${body}"`);

    // Check if both have replied
    const revealed = await checkAndReveal(dailyPrompt.id);

    if (!revealed) {
      const partnerName = user.partner ? user.partner.name : 'your partner';
      await sendSMS(from, `Got it! Waiting on ${partnerName}... 👀`);
    }
  } catch (err) {
    console.error('Webhook error:', err);
  }
});

module.exports = router;
