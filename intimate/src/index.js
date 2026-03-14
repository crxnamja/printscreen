require('dotenv').config();

const express = require('express');
const webhook = require('./webhook');
const { startScheduler, scheduleDailyPrompt, checkAndSend } = require('./scheduler');
const { sendSMS } = require('./twilio');
const supabase = require('./db');

const app = express();
const PORT = process.env.PORT || 3000;

// Twilio sends form-encoded POST data
app.use(express.urlencoded({ extended: false }));
app.use(express.json());

// Mount the SMS webhook
app.use(webhook);

// Health check
app.get('/', (req, res) => {
  res.send('Intimate is running 💌');
});

// Manual test: force-send today's prompt now
app.get('/test/send', async (req, res) => {
  try {
    await scheduleDailyPrompt();
    await checkAndSend();
    res.send('Prompt sent! Check your phones.');
  } catch (err) {
    res.status(500).send(`Error: ${err.message}`);
  }
});

app.listen(PORT, () => {
  console.log(`Intimate running on port ${PORT}`);
  startScheduler();
});
