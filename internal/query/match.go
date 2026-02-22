package query

import (
	"encoding/json"
	"math"
	"strings"
	"time"

	"github.com/polis/learning-loop/internal/db"
)

type ScoredRun struct {
	Run   *db.Run
	Score float64
}

func scoreRun(run *db.Run, keywords []string, now time.Time) float64 {
	var score float64

	// Tag overlap: each matching keyword in tags adds 3.0
	for _, kw := range keywords {
		for _, tag := range run.Tags {
			if strings.EqualFold(tag, kw) {
				score += 3.0
			}
		}
	}

	// Task similarity: keyword presence in task description
	taskLower := strings.ToLower(run.Task)
	for _, kw := range keywords {
		if strings.Contains(taskLower, strings.ToLower(kw)) {
			score += 2.0
		}
	}

	// File reference matching
	filesJSON, err := json.Marshal(run.FilesTouched)
	if err != nil {
		filesJSON = []byte("[]")
	}
	filesLower := strings.ToLower(string(filesJSON))
	for _, kw := range keywords {
		if strings.Contains(filesLower, strings.ToLower(kw)) {
			score += 1.5
		}
	}

	// Outcome signal: failures with patterns are highly informative
	switch run.Outcome {
	case "failure":
		score += 1.0 // failures teach more
	case "partial":
		score += 0.5
	case "success":
		score += 0.3
	}

	// Recency decay: half-life of 7 days
	ts, err := time.Parse(time.RFC3339, run.Timestamp)
	if err == nil {
		daysSince := now.Sub(ts).Hours() / 24
		decay := math.Exp(-0.1 * daysSince) // ~0.5 at 7 days
		score *= (0.5 + 0.5*decay)           // floor at 50% of original score
	}

	return score
}

func extractKeywords(description string) []string {
	// Split on spaces and common punctuation
	splitters := " ,.:;()[]\"'"
	words := strings.FieldsFunc(description, func(c rune) bool {
		return strings.ContainsRune(splitters, c)
	})

	stopWords := map[string]bool{
		"the": true, "a": true, "an": true, "and": true, "or": true,
		"but": true, "in": true, "on": true, "at": true, "to": true,
		"for": true, "of": true, "is": true, "it": true, "this": true,
		"that": true, "with": true, "from": true, "by": true, "be": true,
		"as": true, "are": true, "was": true, "were": true, "been": true,
		"have": true, "has": true, "had": true, "do": true, "does": true,
		"did": true, "will": true, "would": true, "can": true, "could": true,
		"should": true, "may": true, "might": true, "shall": true,
		"not": true, "no": true, "i": true, "we": true, "you": true,
		"he": true, "she": true, "they": true, "me": true, "my": true,
	}

	var keywords []string
	seen := make(map[string]bool)
	for _, w := range words {
		lower := strings.ToLower(w)
		if len(lower) < 2 || stopWords[lower] || seen[lower] {
			continue
		}
		seen[lower] = true
		keywords = append(keywords, lower)
	}
	return keywords
}
