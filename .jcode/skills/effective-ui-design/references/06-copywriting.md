# Copywriting

Practical guidelines on how to write interface text that clearly communicates with people.

## Be Concise

Every word should earn its place.

**Key principle:** More words ≠ more effective communication (people often won't read large chunks).

**Guidelines:**
- Say more with fewer words
- If a word can be removed without losing information, remove it
- Avoid unneeded words: "actually", "basically", "really", "truthfully", "quite"
- Avoid short joining words: "a", "an", "the"
- Avoid introductory phrases: "would you like to", "in order to", "when it comes to", "are you sure", "there are", "it is"
- Use shorter words instead of longer ones
- Keep sentences under 20 words

**Example:**
```
Before: "Would you like to save the article? Don't worry, you'll still
        be able to publish it at a later date. You can always find
        saved articles in your library."

After:  "Save article? Save the article to your library to publish later"
```

## Use Sentence Case

**Sentence case:** Only first word and proper nouns capitalised.
- "This is sentence case"

**Title case:** All words capitalised except minor words.
- "This Is Title Case"

**Why sentence case:**
- Super simple
- Easy to read
- Grammatically correct
- Title case rules aren't universally standardised (often misused)
- Capital letters interrupt scanning
- Uppercase letter when expecting lowercase = confusion = increased cognitive load

## Use Plain and Simple Language

Many people have trouble reading; some have mental disabilities.

**Guidelines:**
- Imagine conversation with 6th grade student unfamiliar with topic
- Avoid jargon (specialised/technical language)
- Avoid slang (informal language between social groups)
- Choose short, simple words over long, complex ones
- Use shortened words: who's, they're, you're

**Example:**
```
Before: "Custom domains are the bee's knees for brands. Look slick and
        help your customers locate you online by executing a custom domain"

After:  "Strengthen your brand with a custom domain. Look professional and
        help your customers find you online by adding a custom domain"
```

## Front-load Text

Put important information at the START of text.

**Why:**
- People scan left to right, down the page
- Key info at front = faster value extraction

**Examples:**
```
Not front-loaded:
- Subscribe to my newsletter to learn UI design
- Sign up today for 30% off
- You should read these 5 UI design eBooks

Front-loaded:
- Learn UI design by subscribing to my newsletter
- 30% off if you sign up today
- 5 UI design eBooks you should read
```

## Use the Inverted Pyramid

Writing structure: most important information first, then supporting info, then background details.

**Benefits:**
- Gets to point quickly
- People who skim first sentence still get main point
- Additional info available for those who need it

**Application:**
- Heading: most important info (complete task without reading more)
- Below heading: supporting info
- Separate screen/section: smaller background details

## Limit the Use of Abbreviations and Acronyms

**Abbreviation:** Shortened word/phrase (dept. = department)
**Acronym:** Initial letters (COB = close of business)

**Problems:**
- Makes people think = increased cognitive load
- Can cause confusion

**Guidelines:**
- Limit use to improve readability
- If you must use, explain initially
- Better: write out fully

**Example:**
```
Confusing: "Apt. no."
Clear: "Apartment number"
```

## Limit the Use of UPPERCASE

**Problems:**
- LOUD AND DIFFICULT TO READ
- When reading, you look at word shape
- Uppercase = same rectangular shape for all words
- Forces reading letter by letter

**Exception:** Short labels to differentiate from other text
- Use: bold weight, small size, increased letter spacing
- Makes less loud, more legible

**Example:**
```
Category label: "FASHION" (14px, bold, 2px letter spacing)
vs
Heading: "Get the look" (18px, regular, 0px letter spacing)
```

## Break Up Content Using Descriptive Headings and Bullets

**Guidelines:**
- Break large info into smaller pieces
- Highlight key info with descriptive headings
- Allows quick scanning
- Better understanding of structure/organisation

### Make Headings Descriptive

**Why:**
- Many scan and don't read supporting text
- Screen readers list all headings - must make sense out of context

**Example:**
```
Vague:       "Location"
Descriptive: "Beautiful waterfront location"

Vague:       "Check-in"
Descriptive: "Fast check-in experience"
```

## Avoid Using "my" on Form Labels

**Problem:** "My email address" refers to interface's email, not user's.

**Guidelines:**
- Using "your" is clearer but usually unnecessary
- Keep simple - avoid both "my" and "your"
- Be concise
- Be consistent throughout interface

**Example:**
```
Confusing: "My email"
Clearer: "Your email"
Best: "Email"
```

## Avoid Ambiguous Confirmation Labels

Dialog buttons must be unambiguous when read alongside the question.

```
Bad:  "Do you wish to cancel this order?"  [OK] [Cancel]
      → Does "Cancel" cancel the order, or cancel the cancel?

Good: "Do you wish to cancel this order?"  [Yes] [No]

Best: "Cancel this order?"  [Cancel order] [Keep order]
      → Verb + noun removes all doubt
```

This is especially dangerous with destructive actions. If unsure, use the button text formula from the Buttons chapter: **verb + noun**.

## Use Vocabulary Consistently

Use same word consistently for same element.

**Inconsistent vocabulary = confusion**

**Common inconsistencies:**
- Publish / post
- Sign up / register
- Log in / sign in
- Delete / remove
- Subscribe / join
- Cart / bag

**Example:** Button says "Add to cart" but page is labelled "Bag" = confusing

## Use Numerals for Numbers

Use numerals, not spelled-out words.

**Advantages:**
- Easier to scan (different shape from letters)
- Quicker to read and understand
- People expect numerical format for figures
- More concise

**Formatting:**
- Use commas: 1,000 not 1000
- Large numbers: 1 billion not 1,000,000,000

**Example:**
```
Before: "Subscribe to join eight hundred and ninety nine designers"
After:  "Subscribe to join 899 designers"
```

## Avoid Full Stops if Possible

**Guidelines:**
- Most UI text should be short enough not to need punctuation
- Don't add full stops unless text forms full sentence with commas
- If multiple similar elements, use full stops consistently across them
- Removing unnecessary full stops simplifies interface

## Ensure Text Length is Similar Across Similar Interface Elements

**When multiple text blocks aligned in row:**
- Try to make them same length
- More alignment = more organised, simpler look
- Faster and easier to understand

## Ensure Text Links Describe Their Destination

**Problems with generic text ("learn more", "read more", "click here"):**
- Harder to scan (forced to read surrounding text)
- Screen readers list all links - generic names don't make sense out of context
- Multiple "learn more" links could seem like same destination

**Solutions:**
- Use descriptive link text: "Explore templates", "Email marketing features"
- Or turn heading into link

**Never use "click here":**
- Inaccessible and difficult to scan
- Unnecessary to tell people how to use link
- "Click" inaccurate for mobile/keyboard/voice users

## Write Clear Error Messages

**Error messages should:**
- Let people know problem occurred
- Explain why it happened
- Provide solution to fix and move forward

**Tips:**
- Never blame user
- Be positive and helpful
- Be concise - avoid "please", "sorry", "oops"
- Keep language clear, conversational
- Avoid technical jargon
- Make headings and buttons descriptive

**Example:**
```
Bad:  "Oops, something went wrong! Your payment wasn't successful
      as an error occurred" [Ok]

Good: "Payment failed. Update your payment details and try again"
      [Update payment details]
```

## Design Empty States

An empty container with no content is never neutral — users cannot tell whether it is loading, broken, or simply unused. Every screen that can be empty needs an intentionally designed empty state.

### Three Types of Empty State

| Type | Trigger | Tone |
|------|---------|------|
| **First-use** | User has not yet created content | Encouraging — explain what belongs here and how to start |
| **User-cleared** | All items completed or removed | Celebratory — confirm the accomplishment ("All caught up!") |
| **No results** | Search or filter returns nothing | Helpful — suggest corrections ("Check spelling" or "Clear filters") |

### Content Anatomy

1. **Headline** (required) — short, plain-language summary: "No projects yet", "No results for 'xyzzy'"
2. **Description** (required, 1-2 sentences) — explain what this area is for and why it is empty
3. **CTA button** (situational) — links directly to the action that fills the state. Use verb + noun: "Create project", "Add first task". Not every empty state needs a CTA — cleared states often just need a confirmation message.
4. **Illustration or icon** (optional) — reinforces the message. Use `alt=""` on decorative illustrations.

**Guidelines:**
- First-use empty states are one of the most effective onboarding mechanisms — they teach in context, at the moment of need, without modal tours or coach marks
- Match the message to the specific scenario — never use a generic "Nothing here" across all empty states
- Keep it short: one headline, one supporting line, one action at most
- Never blame the user in no-results states: "We couldn't find anything" not "You didn't enter valid search terms"
- When the empty state appears dynamically (e.g. after filtering), use `role="status"` so screen readers announce the change
- Consider starter/sample content as an alternative for first-use states — pre-loaded templates eliminate the empty state entirely

## Chapter Summary

1. Be concise - avoid unneeded words, use short words, keep sentences under 20 words
2. Use sentence case; limit uppercase (loud, difficult to read)
3. Avoid jargon, slang, abbreviations - keep language simple and conversational
4. Front-load text - put most important information at start
5. Break up large info into smaller pieces with descriptive headings
6. Design every empty state intentionally — explain what belongs there, why it is empty, and what to do next
