
nPk = (n, k) ->
  return 0 if k > n
  result = 1
  result *= m for m in [n-k+1..n]
  result

nCk = (n, k) ->
  return 1 if k == 0
  k_fact = 1
  k_fact *= m for m in [1..k]
  nPk(n, k) / k_fact

log2 = (n) -> Math.log(n) / Math.log(2)

# ------------------------------------------------------------------------------
# minimum entropy search -------------------------------------------------------
# ------------------------------------------------------------------------------
#
# takes a list of overlapping matches, returns the non-overlapping sublist with
# minimum entropy. O(nm) dp alg for length-n password with m candidate matches.
# ------------------------------------------------------------------------------

minimum_entropy_match_sequence = (password, matches) ->
  bruteforce_cardinality = calc_bruteforce_cardinality password # e.g. 26 for lowercase
  up_to_k = []      # minimum entropy up to k.
  backpointers = [] # for the optimal sequence of matches up to k, holds the final match (match.j == k). null means the sequence ends w/ a brute-force character.
  for k in [0...password.length]
    # starting scenario to try and beat: adding a brute-force character to the minimum entropy sequence at k-1.
    up_to_k[k] = (up_to_k[k-1] or 0) + log2 bruteforce_cardinality
    backpointers[k] = null
    for match in matches when match.j == k
      [i, j] = [match.i, match.j]
      candidate_entropy = (up_to_k[i-1] or 0) + calc_entropy(match)
      if candidate_entropy < up_to_k[j]
        up_to_k[j] = candidate_entropy
        backpointers[j] = match

  # walk backwards and decode the best sequence
  match_sequence = []
  k = password.length - 1
  while k > 0
    match = backpointers[k]
    if match
      match_sequence.push match
      k = match.i - 1
    else
      k -= 1
  match_sequence.reverse()

  # fill in the blanks between pattern matches with bruteforce "matches"
  # that way the match sequence fully covers the password: match1.j == match2.i - 1 for every adjacent match1,match2.
  make_bruteforce_match = (i, j) ->
    pattern: 'bruteforce'
    i: i
    j: j
    token: password[i..j]
    cardinality: bruteforce_cardinality
    display: "bruteforce-with-#{bruteforce_cardinality}-cardinality"
  k = 0
  match_sequence_copy = []
  for match in match_sequence
    [i, j] = [match.i, match.j]
    if i - k > 0
      match_sequence_copy.push make_bruteforce_match(k, i - 1)
    k = j + 1
    match_sequence_copy.push match
  if k < password.length
    match_sequence_copy.push make_bruteforce_match(k, password.length - 1)
  match_sequence = match_sequence_copy

  min_entropy = up_to_k[password.length - 1]
  crack_time = entropy_to_crack_time min_entropy

  # final result object
  entropy: Math.round min_entropy
  match_sequence: match_sequence
  crack_time: crack_time
  crack_time_display: display_time crack_time

# ------------------------------------------------------------------------------
# threat model -- stolen hash catastrophe scenario -----------------------------
# ------------------------------------------------------------------------------
#
# assumes:
# * passwords are stored as salted hashes, different random salt per user.
#   (making rainbow attacks infeasable.)
# * hashes and salts were stolen. attacker is guessing passwords at max rate.
# * attacker has several CPUs at their disposal.
# ------------------------------------------------------------------------------

# about 10 ms per guess for bcrypt/scrypt/PBKDF2 with an appropriate work factor.
# adjust accordingly if you use another hash function, possibly by
# several orders of magnitude!
SINGLE_GUESS = .010
NUM_ATTACKERS = 100 # number of cores guessing in parallel.

SECONDS_PER_GUESS = SINGLE_GUESS / NUM_ATTACKERS

entropy_to_crack_time = (entropy) -> .5 * Math.pow(2, entropy) * SECONDS_PER_GUESS # average, not total

# ------------------------------------------------------------------------------
# entropy calcs -- one function per match pattern ------------------------------
# ------------------------------------------------------------------------------

calc_entropy = (match) ->
  return match.entropy if match.entropy?
  match.entropy = switch match.pattern
    when 'repeat'     then repeat_entropy     match
    when 'sequence'   then sequence_entropy   match
    when 'digits'     then digits_entropy     match
    when 'year'       then year_entropy       match
    when 'date'       then date_entropy       match
    when 'spatial'    then spatial_entropy    match
    when 'dictionary' then dictionary_entropy match

repeat_entropy = (match) ->
  cardinality = calc_bruteforce_cardinality match.token
  log2 (cardinality * match.token.length)

sequence_entropy = (match) ->
  first_chr = match.token[0]
  if first_chr in ['a' or '1']
    base_entropy = 1
  else
    if first_chr.match /\d/
      base_entropy = log2(10) # digits
    else if first_chr.match /[a-z]/
      base_entropy = log2(26) # lower
    else
      base_entropy = log2(26) + 1 # extra bit for uppercase
  if not match.ascending
    base_entropy += 1 # extra bit for descending instead of ascending
  base_entropy + log2 match.token.length

digits_entropy = (match) -> log2 Math.pow(10, match.token.length)

NUM_YEARS = 119 # years match against 1900 - 2019
NUM_MONTHS = 12
NUM_DAYS = 31

year_entropy = (match) -> log2 NUM_YEARS

date_entropy = (match) ->
  if match.year < 100
    entropy = log2(NUM_DAYS * NUM_MONTHS * 100) # two-digit year
  else
    entropy = log2(NUM_DAYS * NUM_MONTHS * NUM_YEARS) # four-digit year
  if match.separator
    entropy += 2 # add two bits for separator selection [/,-,.,etc]
  entropy

spatial_entropy = (match) ->
  if match.graph in ['qwerty', 'dvorak']
    s = KEYBOARD_STARTING_POSITIONS
    d = KEYBOARD_AVERAGE_DEGREE
  else
    s = KEYBOARD_STARTING_POSITIONS
    d = KEYPAD_AVERAGE_DEGREE
  possibilities = 1
  L = match.token.length
  t = match.turns
  # calculates the number of possible patterns w/ length L or less with t turns or less.
  for i in [2..L]
    possible_turns = Math.min(t, i - 1)
    for j in [1..possible_turns]
      possibilities += nCk(i - 1, j - 1) * d * s * i
  log2 possibilities

dictionary_entropy = (match) ->
  entropy = log2 match.rank
  entropy += extra_uppercase_entropy(match)
  entropy += extra_l33t_entropy(match)
  entropy

START_UPPER = /^[A-Z][^A-Z]+$/
END_UPPER = /^[^A-Z]+[A-Z]$/
ALL_UPPER = /^[^a-z]+$/
ALL_LOWER = /^[^A-Z]+$/

extra_uppercase_entropy = (match) ->
  word = match.token
  return 0 if word.match ALL_LOWER
  # a capitalized word is the most common capitalization scheme,
  # so it only doubles the search space (uncapitalized + capitalized): 1 extra bit of entropy.
  # allcaps and end-capitalized are common enough too, underestimate as 1 extra bit to be safe.
  for regex in [START_UPPER, ALL_UPPER, END_UPPER]
    return 1 if word.match regex
  # otherwise calculate the number of ways to capitalize U+L uppercase+lowercase letters with U uppercase letters or less.
  # or, if there's more uppercase than lower (for e.g. PASSwORD), the number of ways to lowercase U+L letters with L lowercase letters or less.
  U = (chr for chr in word when chr.match /[A-Z]/).length
  L = (chr for chr in word when chr.match /[a-z]/).length
  possibilities = 1
  possibilities += nCk(U + L, i) for i in [1..Math.min(U, L)]
  log2 possibilities

extra_l33t_entropy = (match) ->
  return 0 if not match.l33t
  possibilities = 1
  for unsubbed, subbed in match.sub
    U = (chr for chr in match.token when chr == unsubbed).length # number of unsubbed characters.
    S = (chr for chr in match.token when chr == subbed).length   # number of subbed characters.
    possibilities += nCk(U + S, i) for i in [1..Math.min(U, S)]  # similar math as uppercase entropy.
  log2 possibilities

bruteforce_entropy = (match) -> log2 Math.pow(match.cardinality, match.token.length)

# utilities --------------------------------------------------------------------

calc_bruteforce_cardinality = (password) ->
  [lower, upper, digits, symbols] = [false, false, false, false]
  for chr in password
    ord = chr.charCodeAt(0)
    if 0x30 <= ord <= 0x39
      digits = true
    if 0x41 <= ord <= 0x5a
      upper = true
    if 0x61 <= ord <= 0x7a
      lower = true
    else
      symbols = true
  c = 0
  c += 10 if digits
  c += 26 if upper
  c += 26 if lower
  c += 33 if symbols
  c

display_time = (seconds) ->
  minute = 60
  hour = minute * 60
  day = hour * 24
  month = day * 31
  year = month * 12
  century = year * 100
  if seconds < minute
    'instant'
  else if seconds < hour
    "#{1 + Math.ceil(seconds / minute)} minutes"
  else if seconds < day
    "#{1 + Math.ceil(seconds / hour)} hours"
  else if seconds < month
    "#{1 + Math.ceil(seconds / day)} days"
  else if seconds < year
    "#{1 + Math.ceil(seconds / month)} months"
  else if seconds < century
    "#{1 + Math.ceil(seconds / year)} years"
  else
    'centuries'