CREATE TABLE users (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  name TEXT NOT NULL,
  phone TEXT NOT NULL UNIQUE,
  partner_id UUID REFERENCES users(id),
  timezone TEXT DEFAULT 'America/Chicago',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE prompts (
  id SERIAL PRIMARY KEY,
  category TEXT NOT NULL,
  text TEXT NOT NULL,
  mms_url TEXT,
  active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE daily_prompts (
  id SERIAL PRIMARY KEY,
  prompt_id INTEGER REFERENCES prompts(id) NOT NULL,
  scheduled_at TIMESTAMPTZ NOT NULL,
  sent_at TIMESTAMPTZ,
  reveal_sent_at TIMESTAMPTZ,
  date DATE NOT NULL UNIQUE,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE responses (
  id SERIAL PRIMARY KEY,
  daily_prompt_id INTEGER REFERENCES daily_prompts(id) NOT NULL,
  user_id UUID REFERENCES users(id) NOT NULL,
  body TEXT,
  media_url TEXT,
  received_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(daily_prompt_id, user_id)
);
