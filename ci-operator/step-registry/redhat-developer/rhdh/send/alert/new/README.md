# RHDH Alert Steps

This directory contains two alert steps for sending Slack notifications:

## 1. `redhat-developer-rhdh-send-alert` (Original)

**Use for:** All branches except `main`

**Features:**
- Original alert logic
- ReportPortal URLs shown per deployment
- Basic failure handling
- Maintains backward compatibility

## 2. `redhat-developer-rhdh-send-alert-new` (New)

**Use for:** `main` branch only

**Features:**
- Simplified, more maintainable logic
- ReportPortal URL shown at job level (not per deployment)
- Enhanced Data Router failure handling
- Better status categorization (warning vs failed)
- Cleaner message formatting

## Key Differences

### ReportPortal URL Handling
- **Original**: Shows ReportPortal URL per deployment in the detailed breakdown
- **New**: Shows ReportPortal URL at the main job level, right after the logs link

### Data Router Failure Handling
- **Original**: No special handling for Data Router failures
- **New**: Distinguishes between test failures and Data Router failures:
  - Test failures: `:failed:` emoji
  - Data Router failures: `:warning:` emoji + "Data Router failed" note

### Message Structure
- **Original**: Complex nested logic with deployment-specific ReportPortal URLs
- **New**: Linear flow with job-level ReportPortal URL and simplified logic

## Usage

### For main branch (use new step):
```yaml
- as: send-alert
  commands: redhat-developer-rhdh-send-alert-new
```

### For other branches (use original step):
```yaml
- as: send-alert
  commands: redhat-developer-rhdh-send-alert
```

## Migration

When ready to migrate all branches to the new logic:
1. Update the original step to use the new logic
2. Remove the "new" step
3. Update all branch configurations to use the original step

This approach allows for gradual testing and validation of the new logic on the main branch before rolling it out to all branches.
