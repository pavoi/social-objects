# TikTok Live Comment Classification

You are classifying comments from a TikTok Live shopping stream for a jewelry brand (PAVOI).

## Task

For each comment, determine TWO SEPARATE things:
1. **Sentiment (s)**: The emotional tone - ONLY use codes: p, u, or n
2. **Category (c)**: The type of comment - ONLY use codes: cc, pr, qc, ti, pc, or g

**IMPORTANT**: Sentiment and category are DIFFERENT fields with DIFFERENT valid codes. Never mix them up.

## Sentiment Values (for "s" field - ONLY these 3 codes are valid)
- **p** = positive: Happy, excited, complimentary, satisfied
- **u** = neutral: Informational, questions, greetings, reactions, emoji-only
- **n** = negative: Frustrated, disappointed, complaining, reporting problems

## Category Values (for "c" field - ONLY these 6 codes are valid)
- **cc** = concern_complaint: Issues, complaints, problems with products/service
- **pr** = product_request: Asking for specific items, sizes, colors, restocks
- **qc** = question_confusion: Questions about products, pricing, process, stream
- **ti** = technical_issue: Audio/video problems, app issues, checkout problems
- **pc** = praise_compliment: Positive feedback, love for products/brand
- **g** = general: Greetings, reactions, emoji-only, spam, doesn't fit others

## Response Format

Respond with ONLY a JSON array. Each object must have exactly:
- `id`: The comment ID (integer from input)
- `s`: Sentiment code (MUST be p, u, or n - nothing else)
- `c`: Category code (MUST be cc, pr, qc, ti, pc, or g - nothing else)

## Examples

Input:
```json
[
  {"id": 1, "text": "Love this bracelet!", "user": "jenny"},
  {"id": 2, "text": "Do you have size 8?", "user": "maria"},
  {"id": 3, "text": "Why did my ring tarnish", "user": "cari"},
  {"id": 4, "text": "Audio is cutting out", "user": "lisa"},
  {"id": 5, "text": "Hi from Texas!", "user": "amy"},
  {"id": 6, "text": "What is this made of?", "user": "kim"},
  {"id": 7, "text": "😍😍😍", "user": "sara"},
  {"id": 8, "text": "🔥", "user": "bot123"}
]
```

Output:
```json
[{"id":1,"s":"p","c":"pc"},{"id":2,"s":"u","c":"pr"},{"id":3,"s":"n","c":"cc"},{"id":4,"s":"n","c":"ti"},{"id":5,"s":"u","c":"g"},{"id":6,"s":"u","c":"qc"},{"id":7,"s":"p","c":"g"},{"id":8,"s":"u","c":"g"}]
```

Note in the output above:
- Questions get sentiment "u" (neutral) and category "qc" - NOT s="qc"!
- Emoji reactions get category "g" (general) - NOT s="g"!
- The "s" field is ALWAYS p, u, or n. Never qc, pr, g, etc.

## Guidelines

- **Critical**: The "s" field must ONLY be p, u, or n. Never use category codes for sentiment.
- Be consistent: Similar comments should get the same classification
- When uncertain between categories, prefer the more specific one
- Product-related questions are category "qc", availability questions are "pr"
- Frustration about a product issue is "cc", not "qc"
- Emoji-only comments and spam: sentiment "u", category "g"

---

Classify these comments:
