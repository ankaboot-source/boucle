# Forms

Form patterns and principles to help people complete forms more quickly and easily.

## Stack Forms in a Single Column Layout

Multi-column forms are common but problematic.

**Single column benefits:**
- More efficient (decreases interaction cost)
- Consistent downward momentum
- Decreases cognitive load (no decisions about which field next)
- Less chance of missing fields
- Screen magnifier users won't miss second column

### Stack Labels on Top of Inputs

**Avoid labels to the left:**
- Increases cognitive load and interaction cost
- Slows form completion
- Large/inconsistent gap between label and input
- Eyes zig-zag between label and input
- Right-aligned labels = jagged left edge = harder to scan
- Long labels may wrap onto multiple lines

**Labels on top:**
- Neat and tidy
- Simple, consistent downward momentum
- Eyes see label and input in single focus

### Stack Checkboxes and Radio Buttons Vertically

Same reasons as above, plus clearly separates options.

### What About Height?

Single column takes more vertical space.

**To reduce height:**
- Short related fields can be placed side by side
- Example: credit card expiry date and CVC
- Keep within single column bounds

**If form is too long:**
- Break into multiple smaller steps

## Minimise the Number of Form Fields

Only ask for essential information.

**More fields cause:**
- Higher chance of abandonment
- More work for users
- Higher chance of mistakes
- More development time

## Mark Optional Fields

Add "(optional)" to optional field labels.

### Try to Avoid Optional Fields by Using Opt-ins

**Instead of optional field:**
1. Use checkbox to ask if user wants to provide info
2. If checked, reveal required field

**Benefits:**
- Simplifies form
- Users who don't want feature don't see extra field

**Example:**
```
Instead of: Mobile number (optional)
Use: [checkbox] Receive updates via text message
     [if checked] Mobile number *
```

## Mark Both Required and Optional Fields

**Especially important for cognitive disabilities.**

**Guidelines:**
- Mark required: asterisk * OR word "required"
- Mark optional: word "(optional)"

### Why Mark Required Fields

**Problem with only marking optional:**
- Instructions at top often skipped
- People left guessing if field is required

**Using asterisk *:**
- Concise and familiar
- Still need instructions, but doesn't matter if missed
- Easy to scan form for required fields
- DON'T colour asterisks red (indicates error)

**Using word "required":**
- Crystal clear
- No additional instructions needed
- Adds clutter but safest

### When You Don't Need to Mark Required

- No optional fields in your product
- Short familiar forms (login, newsletter)
- Single question per screen with explanation
- Usability testing validates it's not needed

## Match Field Width to the Intended Input

**Field width = expectation for amount of information.**

**Guidelines:**
- Width should match expected input length
- DON'T set all fields to same width
- Example: 4-digit postcode = 4-character width
- If variable length: accommodate most common or longest case

**Wide field + small input = confusion, increased cognitive load.**

## Stick with Conventional Form Field Styles

Use patterns people are familiar with (Jakob's Law).

**Unconventional styles cause:**
- Unclear where to put answers
- Labels inside fields make fields look filled
- Hard to distinguish filled vs empty

**If modifying form fields:**
- Keep iconic elements of conventional fields
- Example: Radio buttons need circle on left to indicate single selection

## Display Hints Above Form Fields

**Hint/helper text:** Additional information to help complete a field.

**DON'T hide hints in tooltips** if critical - risk of being missed.

**Place hints ABOVE fields:**
- Helps avoid errors
- Maintains downward momentum
- User sees hint BEFORE filling field

**DON'T place hints below fields:**
- Can be covered by autofill menus
- Can be covered by on-screen keyboards

## Don't Use Placeholder Text Instead of a Label

**Placeholder text:** Short hint inside input before value entered.

**Problems with placeholder as label:**
- Disappears when typing (users forget what field is for)
- Can be mistaken as pre-filled (skipped)
- Contrast almost always inaccessible

### Form Label Tips

- Always display short descriptive label above fields
- Add hint under label if needed
- Avoid placeholder text (can make inputs look pre-filled)
- Avoid instructional verbs: "Enter email here", "Type your email" (already implied)

**Exception:** Single search fields with accessible contrast (4.5:1) and accessible label for screen readers.

## Ensure Form Field Labels Are Close to Their Fields

**Common mistake:** Labels spaced far from inputs.

**Guideline:** Related elements spaced closer together.

**Benefits:**
- Clear which labels relate to which fields
- Eyes only need one focus per field (decreased interaction cost)

## Try to Use Radio Buttons Instead of Dropdowns

For ~10 options or fewer, consider radio buttons.

**Dropdown problems:**
- High interaction cost (multiple precise interactions)
- Difficult for motor impairments
- Can be mistaken as filled and skipped
- Options hidden initially (hard to scan)

**Radio button benefits:**
- One quick interaction
- Always visible
- Easy to compare options

**Exception:** If saving space is priority, dropdowns are fine.

## Use an Autocomplete Instead of a Long Dropdown

For long lists, use autocomplete search (predictive search).

**Benefits:**
- Faster than scrolling through long list
- Suggestions appear as user types

**Tips:**
- Suitable when users know what they're looking for
- For browsing: break dropdown into multiple separate fields
- Keep suggestions to ~10 or fewer (avoid choice paralysis)
- Highlight differences between suggestions in bold

## Use Steppers for Numeric Fields Instead of Dropdowns

**Stepper:** Increase/decrease number with single button press, or type number directly.

**Benefits:**
- Lower interaction cost
- Example: 2 adults, 1 child, 1 infant
  - Dropdowns: 6 clicks + 3 scrolls
  - Steppers: 4 clicks

**Design tips:**
- Minimum 48pt x 48pt button target area
- Place buttons horizontally (more space between = less mistakes)
- Use "+/-" buttons (not arrows/chevrons - differentiates from dropdowns)
- Not suitable for large numeric changes

## Use a Checkbox or Toggle Switch for 2 Options

For simple on/off where default is off.

**Lower interaction cost than dropdowns, more compact than 2 radio buttons.**

### Checkbox Usage
Use when submit button needed before option takes effect.
- Label describes what happens when checked
- Example: "Receive news and special offers" + Register button

### Toggle Switch Usage
Use for options that take immediate effect.
- Label describes what happens when switch is on
- No submit button needed
- Example: "Pay annually and save 10%" (instantly changes pricing)

## Use Positive Phrasing for Checkboxes

Describe what WILL happen when selected, not what WON'T.

**Test:** Replace checkbox with "yes" - if unclear, it's negative phrasing.

```
Bad:  "Don't allow automatic updates" ("Yes, don't allow...")
Good: "Allow automatic updates" ("Yes, allow...")
```

## Break Up Long Forms into Multiple Steps

**Benefits:**
- Decreases cognitive load
- Reduces mistakes
- Improves completion rates
- Seems less overwhelming
- Focus on one thing at a time

**Tips:**
- Let people know how long and what they'll need before starting
- 30 questions = 6 steps of 5 related questions (not 30 steps)
- Order questions easiest to hardest (early wins)
- Indicate progress (Goal-Gradient Effect: more motivated near end)
- Allow review and changes before submitting
- Display success message and what to expect next

## Group Related Fields Under Headings

If you can't break into steps, group related fields with headings.

**Benefits:**
- Seems less overwhelming
- Easier to understand and complete

## Ensure Form Field Borders Are High Contrast

**Low contrast form fields = most common UI design mistake.**

**Problems:**
- Some can't see light borders (low vision, sunny conditions)
- Without borders, unclear how to interact

**Guideline:** Form field borders minimum 3:1 contrast.

**Applies to all UI elements:**
- Buttons, toggle switches, inputs
- Steppers, checkboxes, radio buttons

**If not decorative, needs sufficient contrast.**

## Use 16px Minimum Font Size for Inputs on Mobile

iOS Safari automatically zooms into input fields when font size is below 16px. This is intentional behaviour to ensure readability, but can be disorienting.

**Solution:** Ensure input fields have at least 16px font size on mobile devices.

```css
/* Responsive approach */
input, select, textarea {
  font-size: 16px;  /* Prevents iOS zoom */
}

@media (min-width: 768px) {
  input, select, textarea {
    font-size: 14px;  /* Smaller on desktop if desired */
  }
}
```

**Common pattern (Tailwind):**
- `text-sm` (14px) for labels and UI text
- `text-base` (16px) for input fields on mobile

**Do NOT disable zoom** via `maximum-scale=1` in the viewport meta tag - this breaks accessibility for users who need to zoom.

## Choose Your Form Validation Approach

Even well-designed forms = people make mistakes.

### 1. Validate on Submit of the Form

Simplest, easiest to implement.

**Guidelines:**
- Display error message ABOVE invalid fields (below can be covered by keyboards/autofill)
- Use red border + background shade + icon (not colour alone)
- List multiple errors at top with links to invalid fields
- DON'T disable submit button

**Advantages:**
- Simple to implement
- Allows focus on completion without distractions

**Disadvantages:**
- No feedback while completing
- Multiple errors at once = overwhelming
- Must navigate entire form again

### 2. Validate After People Leave a Field (On Blur)

Also called inline validation.

**Guidelines:**
- Remove error message once error resolved
- Combines with instant validation for removal

**Advantages:**
- Immediate feedback
- Fix errors faster while context fresh
- Can provide positive feedback (password meets criteria)

**Disadvantages:**
- Distracting to switch between answering and fixing
- Doesn't work well for groups (checkbox lists)
- More complex to implement

### 3. Validate Instantly as People Type

Waits until typing stops, then validates (with delay).

**Advantages:**
- Helps work toward answer (password criteria, username availability)
- Immediate feedback
- Fix errors faster

**Disadvantages:**
- Premature error messages frustrate users
- Hard to know when typing is finished (different speeds)
- More complex to implement

### Use :user-valid and :user-invalid for CSS-Only Validation Feedback

`:user-valid` and `:user-invalid` (Baseline 2023) solve the biggest problem with CSS form validation: premature error display. Unlike `:invalid` (which fires immediately, even before the user types anything), these pseudo-classes only activate *after the user has interacted* with the field.

```css
/* No red borders on page load — only after user interaction */
input:user-invalid {
  border-color: var(--error);
  background: var(--error-fill);
}

input:user-valid {
  border-color: var(--success);
}
```

**Why this matters:**
- `:invalid` marks empty required fields as errors on page load — frustrating and distracting
- `:user-invalid` waits until the user has attempted to fill the field, then shows feedback
- Works with HTML validation attributes (`required`, `pattern`, `type="email"`, `min`, `max`)
- Reduces JavaScript needed for basic validation timing

**Combine with HTML validation** for zero-JavaScript inline validation:

```html
<label for="email">Email *</label>
<input id="email" type="email" required>
<!-- :user-invalid activates after user types an invalid email and leaves the field -->
```

**Still use JavaScript for:**
- Custom validation messages (the native browser messages are ugly and inconsistent)
- Server-side validation (username availability, etc.)
- Multi-field validation (password confirmation)

## Chapter Summary

1. Single column layout maintains consistent downward momentum
2. Mark both required and optional fields
3. Match field width to intended input
4. Consider radio buttons, autocomplete, or steppers instead of dropdowns
5. Break long forms into multiple smaller steps
6. Use `:user-valid`/`:user-invalid` for CSS validation that respects user interaction timing
