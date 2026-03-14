-- ============================================
-- Dunn Bet — Friend Prediction Market
-- Supabase / Postgres Schema
-- ============================================

-- 1. Profiles (extends Supabase auth.users)
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  wallet_address TEXT, -- Base USDC wallet for withdrawals
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 2. Groups (friend circles)
CREATE TABLE groups (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  invite_code TEXT UNIQUE NOT NULL DEFAULT encode(gen_random_bytes(6), 'hex'),
  creator_id UUID NOT NULL REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 3. Group Members (with per-group balance in USDC cents)
CREATE TABLE group_members (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  balance BIGINT NOT NULL DEFAULT 0, -- in USDC cents (100 = $1.00)
  joined_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(group_id, user_id)
);

-- 4. Markets (bets within a group)
CREATE TABLE markets (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
  creator_id UUID NOT NULL REFERENCES profiles(id),
  question TEXT NOT NULL,
  description TEXT,
  resolution_date TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved', 'voided')),
  resolved_outcome TEXT CHECK (resolved_outcome IN ('yes', 'no')),
  initial_probability SMALLINT NOT NULL DEFAULT 50 CHECK (initial_probability BETWEEN 1 AND 99),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 5. Orders (limit orders on the order book)
CREATE TABLE orders (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  market_id UUID NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id),
  side TEXT NOT NULL CHECK (side IN ('yes', 'no')),
  price SMALLINT NOT NULL CHECK (price BETWEEN 1 AND 99), -- cents per share
  quantity INT NOT NULL CHECK (quantity > 0),
  filled_quantity INT NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'partial', 'filled', 'cancelled')),
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX idx_orders_matching ON orders(market_id, status, side, price, created_at);

-- 6. Trades (matched order pairs)
CREATE TABLE trades (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  market_id UUID NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
  yes_order_id UUID NOT NULL REFERENCES orders(id),
  no_order_id UUID NOT NULL REFERENCES orders(id),
  yes_user_id UUID NOT NULL REFERENCES profiles(id),
  no_user_id UUID NOT NULL REFERENCES profiles(id),
  price SMALLINT NOT NULL, -- YES price in cents; NO price = 100 - price
  quantity INT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- 7. Positions (net holdings per user per market per side)
CREATE TABLE positions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id),
  market_id UUID NOT NULL REFERENCES markets(id) ON DELETE CASCADE,
  side TEXT NOT NULL CHECK (side IN ('yes', 'no')),
  quantity INT NOT NULL DEFAULT 0,
  UNIQUE(user_id, market_id, side)
);

-- ============================================
-- Row-Level Security
-- ============================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone can read profiles" ON profiles FOR SELECT USING (true);
CREATE POLICY "Users update own profile" ON profiles FOR UPDATE USING (auth.uid() = id) WITH CHECK (auth.uid() = id);

ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members can read their groups" ON groups FOR SELECT
  USING (EXISTS (SELECT 1 FROM group_members WHERE group_id = groups.id AND user_id = auth.uid()));
CREATE POLICY "Anyone can read group by invite code" ON groups FOR SELECT USING (true);
CREATE POLICY "Authenticated can create groups" ON groups FOR INSERT WITH CHECK (auth.uid() = creator_id);

ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Members can read group members" ON group_members FOR SELECT
  USING (EXISTS (SELECT 1 FROM group_members gm WHERE gm.group_id = group_members.group_id AND gm.user_id = auth.uid()));
CREATE POLICY "Users can insert themselves" ON group_members FOR INSERT WITH CHECK (auth.uid() = user_id);

ALTER TABLE markets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Group members can read markets" ON markets FOR SELECT
  USING (EXISTS (SELECT 1 FROM group_members WHERE group_id = markets.group_id AND user_id = auth.uid()));
CREATE POLICY "Group members can create markets" ON markets FOR INSERT
  WITH CHECK (EXISTS (SELECT 1 FROM group_members WHERE group_id = markets.group_id AND user_id = auth.uid()));

ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Group members can read orders" ON orders FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM markets m JOIN group_members gm ON gm.group_id = m.group_id
    WHERE m.id = orders.market_id AND gm.user_id = auth.uid()
  ));

ALTER TABLE trades ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Group members can read trades" ON trades FOR SELECT
  USING (EXISTS (
    SELECT 1 FROM markets m JOIN group_members gm ON gm.group_id = m.group_id
    WHERE m.id = trades.market_id AND gm.user_id = auth.uid()
  ));

ALTER TABLE positions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users read own positions" ON positions FOR SELECT USING (auth.uid() = user_id);

-- ============================================
-- Auto-create profile on signup
-- ============================================

CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles(id, display_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'name', split_part(NEW.email, '@', 1)));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================
-- Order Matching Engine
-- ============================================

CREATE OR REPLACE FUNCTION place_order(
  p_market_id UUID,
  p_user_id UUID,
  p_side TEXT,
  p_price INT,
  p_quantity INT
) RETURNS UUID AS $$
DECLARE
  v_order_id UUID;
  v_remaining INT := p_quantity;
  v_cost BIGINT;
  v_match RECORD;
  v_fill_qty INT;
  v_comp_side TEXT;
  v_group_id UUID;
  v_user_balance BIGINT;
BEGIN
  -- Verify caller is authenticated user
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- Validate market is open and get group_id
  SELECT m.group_id INTO v_group_id
  FROM markets m WHERE m.id = p_market_id AND m.status = 'open';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Market is not open';
  END IF;

  -- Validate price
  IF p_price < 1 OR p_price > 99 THEN
    RAISE EXCEPTION 'Price must be between 1 and 99';
  END IF;

  -- Calculate max cost
  v_cost := p_price::BIGINT * p_quantity;

  -- Check and lock user's group balance
  SELECT balance INTO v_user_balance
  FROM group_members
  WHERE group_id = v_group_id AND user_id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Not a member of this group';
  END IF;

  IF v_user_balance < v_cost THEN
    RAISE EXCEPTION 'Insufficient balance. Need % cents, have %', v_cost, v_user_balance;
  END IF;

  -- Debit full potential cost
  UPDATE group_members SET balance = balance - v_cost
  WHERE group_id = v_group_id AND user_id = p_user_id;

  -- Insert order
  INSERT INTO orders(market_id, user_id, side, price, quantity, filled_quantity, status)
  VALUES (p_market_id, p_user_id, p_side, p_price, p_quantity, 0, 'open')
  RETURNING id INTO v_order_id;

  -- Find matching orders on opposite side
  v_comp_side := CASE WHEN p_side = 'yes' THEN 'no' ELSE 'yes' END;

  FOR v_match IN
    SELECT id, user_id, price, quantity - filled_quantity AS available
    FROM orders
    WHERE market_id = p_market_id
      AND side = v_comp_side
      AND status IN ('open', 'partial')
      AND price >= (100 - p_price) -- their price covers the complement
    ORDER BY price DESC, created_at ASC -- best price first, then FIFO
    FOR UPDATE
  LOOP
    EXIT WHEN v_remaining <= 0;

    v_fill_qty := LEAST(v_remaining, v_match.available);

    -- Record the trade
    INSERT INTO trades(market_id, yes_order_id, no_order_id, yes_user_id, no_user_id, price, quantity)
    VALUES (
      p_market_id,
      CASE WHEN p_side = 'yes' THEN v_order_id ELSE v_match.id END,
      CASE WHEN p_side = 'no' THEN v_order_id ELSE v_match.id END,
      CASE WHEN p_side = 'yes' THEN p_user_id ELSE v_match.user_id END,
      CASE WHEN p_side = 'no' THEN p_user_id ELSE v_match.user_id END,
      CASE WHEN p_side = 'yes' THEN p_price ELSE (100 - v_match.price) END,
      v_fill_qty
    );

    -- Update matched order
    UPDATE orders SET
      filled_quantity = filled_quantity + v_fill_qty,
      status = CASE WHEN filled_quantity + v_fill_qty >= quantity THEN 'filled' ELSE 'partial' END
    WHERE id = v_match.id;

    -- Update positions for both parties
    INSERT INTO positions(user_id, market_id, side, quantity)
    VALUES (p_user_id, p_market_id, p_side, v_fill_qty)
    ON CONFLICT(user_id, market_id, side) DO UPDATE SET quantity = positions.quantity + v_fill_qty;

    INSERT INTO positions(user_id, market_id, side, quantity)
    VALUES (v_match.user_id, p_market_id, v_comp_side, v_fill_qty)
    ON CONFLICT(user_id, market_id, side) DO UPDATE SET quantity = positions.quantity + v_fill_qty;

    v_remaining := v_remaining - v_fill_qty;
  END LOOP;

  -- Update our order status
  UPDATE orders SET
    filled_quantity = p_quantity - v_remaining,
    status = CASE
      WHEN v_remaining = 0 THEN 'filled'
      WHEN v_remaining < p_quantity THEN 'partial'
      ELSE 'open'
    END
  WHERE id = v_order_id;

  RETURN v_order_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Cancel Order
-- ============================================

CREATE OR REPLACE FUNCTION cancel_order(p_order_id UUID, p_user_id UUID)
RETURNS VOID AS $$
DECLARE
  v_order RECORD;
  v_refund BIGINT;
  v_group_id UUID;
BEGIN
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT o.*, m.group_id INTO v_order
  FROM orders o JOIN markets m ON m.id = o.market_id
  WHERE o.id = p_order_id AND o.user_id = p_user_id
  FOR UPDATE OF o;

  IF NOT FOUND THEN RAISE EXCEPTION 'Order not found'; END IF;
  IF v_order.status NOT IN ('open', 'partial') THEN RAISE EXCEPTION 'Cannot cancel this order'; END IF;

  v_refund := (v_order.quantity - v_order.filled_quantity)::BIGINT * v_order.price;
  v_group_id := v_order.group_id;

  UPDATE orders SET status = 'cancelled' WHERE id = p_order_id;
  UPDATE group_members SET balance = balance + v_refund
  WHERE group_id = v_group_id AND user_id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Resolve Market (2% platform fee on winnings)
-- ============================================

CREATE OR REPLACE FUNCTION resolve_market(p_market_id UUID, p_user_id UUID, p_outcome TEXT)
RETURNS VOID AS $$
DECLARE
  v_market RECORD;
  v_order RECORD;
  v_pos RECORD;
  v_payout BIGINT;
  v_refund BIGINT;
BEGIN
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  -- Only creator can resolve
  SELECT * INTO v_market FROM markets
  WHERE id = p_market_id AND creator_id = p_user_id AND status = 'open'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Cannot resolve: not creator or market not open';
  END IF;

  -- Set market as resolved
  UPDATE markets SET status = 'resolved', resolved_outcome = p_outcome
  WHERE id = p_market_id;

  -- Cancel all open orders and refund escrowed amounts
  FOR v_order IN
    SELECT id, user_id, price, quantity - filled_quantity AS remaining
    FROM orders WHERE market_id = p_market_id AND status IN ('open', 'partial')
    FOR UPDATE
  LOOP
    UPDATE orders SET status = 'cancelled' WHERE id = v_order.id;
    v_refund := v_order.remaining::BIGINT * v_order.price;
    IF v_refund > 0 THEN
      UPDATE group_members SET balance = balance + v_refund
      WHERE group_id = v_market.group_id AND user_id = v_order.user_id;
    END IF;
  END LOOP;

  -- Pay out winning positions: $0.98 per share (2% platform fee)
  FOR v_pos IN
    SELECT user_id, quantity FROM positions
    WHERE market_id = p_market_id AND side = p_outcome AND quantity > 0
  LOOP
    v_payout := v_pos.quantity::BIGINT * 98; -- 98 cents per share (2% fee)
    UPDATE group_members SET balance = balance + v_payout
    WHERE group_id = v_market.group_id AND user_id = v_pos.user_id;
  END LOOP;

  -- Losing positions get nothing
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Create Group (helper)
-- ============================================

CREATE OR REPLACE FUNCTION create_group(p_name TEXT, p_user_id UUID)
RETURNS UUID AS $$
DECLARE
  v_group_id UUID;
BEGIN
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  INSERT INTO groups(name, creator_id)
  VALUES (p_name, p_user_id)
  RETURNING id INTO v_group_id;

  -- Creator auto-joins with 0 balance
  INSERT INTO group_members(group_id, user_id, balance)
  VALUES (v_group_id, p_user_id, 0);

  RETURN v_group_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Join Group via invite code
-- ============================================

CREATE OR REPLACE FUNCTION join_group(p_invite_code TEXT, p_user_id UUID)
RETURNS UUID AS $$
DECLARE
  v_group_id UUID;
BEGIN
  IF auth.uid() != p_user_id THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT id INTO v_group_id FROM groups WHERE invite_code = p_invite_code;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invalid invite code';
  END IF;

  INSERT INTO group_members(group_id, user_id, balance)
  VALUES (v_group_id, p_user_id, 0)
  ON CONFLICT(group_id, user_id) DO NOTHING;

  RETURN v_group_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
