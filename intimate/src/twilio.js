const twilio = require('twilio');

const client = twilio(
  process.env.TWILIO_ACCOUNT_SID,
  process.env.TWILIO_AUTH_TOKEN
);

const from = process.env.TWILIO_PHONE_NUMBER;

async function sendSMS(to, body, mediaUrl) {
  const params = { from, to, body };
  if (mediaUrl) params.mediaUrl = [mediaUrl];
  return client.messages.create(params);
}

module.exports = { sendSMS };
