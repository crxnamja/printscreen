# Intimate

Daily couples prompt app delivered via SMS. Both partners get the same fun question at a random time each day, reply independently, and get a reveal of each other's answers.

## Setup

1. Copy `.env.example` to `.env` and fill in your Twilio + Supabase credentials
2. Run `supabase/schema.sql` in your Supabase SQL editor
3. Insert your two users into the `users` table (see below)
4. `npm run seed` to load the 30 prompts
5. `npm start` to run the server
6. Set your Twilio phone number's webhook to `https://<your-url>/sms` (POST)

### Insert users

```sql
INSERT INTO users (name, phone) VALUES ('Noah', '+15125551234');
INSERT INTO users (name, phone) VALUES ('Partner', '+15125555678');
UPDATE users SET partner_id = (SELECT id FROM users WHERE name = 'Partner') WHERE name = 'Noah';
UPDATE users SET partner_id = (SELECT id FROM users WHERE name = 'Noah') WHERE name = 'Partner';
```

## Testing locally

```bash
npm start          # starts on port 3000
ngrok http 3000    # expose to Twilio
# Visit http://localhost:3000/test/send to force-send today's prompt
```
