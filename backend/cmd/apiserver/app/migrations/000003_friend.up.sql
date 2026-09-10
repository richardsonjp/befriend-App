-- Onboarding questionnaire, the friend it creates, and its personality versions.

CREATE TABLE question_set (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    version INT NOT NULL UNIQUE,
    questions JSONB NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- At most one active question set.
CREATE UNIQUE INDEX idx_question_set_active ON question_set(is_active) WHERE is_active;

CREATE TABLE onboarding_response (
    user_id UUID PRIMARY KEY REFERENCES "user"(id) ON DELETE CASCADE,
    question_set_id UUID NOT NULL REFERENCES question_set(id),
    answers JSONB NOT NULL,          -- [{question_id, value}] in question order
    consent_at TIMESTAMPTZ NOT NULL, -- consent to sharing answers/activity with us and the AI provider
    completed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE friend (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES "user"(id) ON DELETE CASCADE,
    name VARCHAR(24) NOT NULL,           -- chosen by the user; evolution never changes it
    user_nickname VARCHAR(24) NOT NULL,  -- what the friend calls the user
    born_at TIMESTAMPTZ NOT NULL,        -- onboarding completion: the friend's birth moment
    birth_city VARCHAR(100),
    birth_country CHAR(2),
    birth_lat NUMERIC(4,1),              -- city-level precision only
    birth_lon NUMERIC(4,1),
    birth_tz VARCHAR(64) NOT NULL,
    western_sign VARCHAR(16) NOT NULL,
    chinese_animal VARCHAR(16) NOT NULL,
    chinese_element VARCHAR(8) NOT NULL,
    chinese_polarity VARCHAR(4) NOT NULL,
    feng_shui_star SMALLINT NOT NULL,
    feng_shui_element VARCHAR(8) NOT NULL,
    current_version_id UUID,             -- latest ready personality_version
    next_evolution_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Doubles as the generation queue: pending/failed rows whose next_attempt_at has passed are processed.
CREATE TABLE personality_version (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    friend_id UUID NOT NULL REFERENCES friend(id) ON DELETE CASCADE,
    version INT NOT NULL,
    status VARCHAR(10) NOT NULL,   -- pending | running | ready | failed
    reason VARCHAR(10) NOT NULL,   -- onboarding | evolution
    model VARCHAR(100),
    vocabulary_version INT,
    attempts INT NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    locked_until TIMESTAMPTZ,
    personality JSONB,
    phrasebook JSONB,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (friend_id, version)
);

CREATE INDEX idx_personality_version_due ON personality_version(next_attempt_at) WHERE status IN ('pending', 'failed');

ALTER TABLE friend ADD CONSTRAINT fk_friend_current_version
    FOREIGN KEY (current_version_id) REFERENCES personality_version(id) ON DELETE SET NULL;

INSERT INTO question_set (version, is_active, questions) VALUES (1, TRUE, '[
  {"id": "friend_name", "type": "text", "prompt": "What will you call your friend?", "max_length": 24},
  {"id": "user_nickname", "type": "text", "prompt": "What should your friend call you?", "max_length": 24},
  {"id": "best_time", "type": "choice", "prompt": "When do you feel most like yourself?",
   "options": ["Morning", "Afternoon", "Evening", "Late night"]},
  {"id": "recharge", "type": "choice", "prompt": "How do you recharge?",
   "options": ["Alone", "With a few close friends", "In a big group", "Outdoors"]},
  {"id": "energy", "type": "slider", "prompt": "What energy should your friend have?",
   "min": 1, "max": 10, "min_label": "Calm", "max_label": "Chaotic"},
  {"id": "talk_style", "type": "choice", "prompt": "How should your friend talk to you?",
   "options": ["Gentle", "Playful teasing", "Straight-talking", "Nerdy"]},
  {"id": "computer_use", "type": "choice", "prompt": "What is your computer mostly for?",
   "options": ["Work", "Study", "Creating", "Gaming", "Browsing"]},
  {"id": "stress_support", "type": "choice", "prompt": "When you are stressed, what helps most?",
   "options": ["A distraction", "Encouragement", "Some space", "A reminder to take a break"]},
  {"id": "humor", "type": "choice", "prompt": "What kind of humor do you like?",
   "options": ["Puns", "Sarcasm", "Wholesome", "Absurd"]},
  {"id": "chattiness", "type": "slider", "prompt": "How chatty should your friend be?",
   "min": 1, "max": 10, "min_label": "Rarely speaks", "max_label": "Chatterbox"}
]'::jsonb);
