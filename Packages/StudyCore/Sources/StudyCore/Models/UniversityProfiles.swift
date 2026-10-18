import Foundation

// The university profiles as data. Edit the JSON, not code: the coach reads only
// `UniversityProfile`'s fields. The one profile here is an invented example university (a module
// handbook of 180 h per 6 credits = 30 h per credit).

extension UniversityProfile {
    /// Example University (an invented profile).
    public static let exampleUniversity: UniversityProfile = decode(exampleUniversityJSON) ?? .ects

    /// A plain ECTS profile without terms (the fallback if a data file does not decode).
    public static let ects = UniversityProfile(
        id: "ects", name: "ECTS", creditSystem: "ECTS", hoursPerCredit: 30, defaultCredits: 6,
        sittingsPerTerm: 1, attempts: 3, freeAttempt: false, gradeImprovement: false,
        gradeScale: "", withdrawRule: "", practiceExamSources: [], localTerms: [:],
        writtenExamMinutes: 60...120, defaultExamMinutes: 90, terms: []
    )

    static func decode(_ json: String) -> UniversityProfile? {
        do {
            return try JSONDecoder().decode(UniversityProfile.self, from: Data(json.utf8))
        } catch {
            Log.database.error("University profile does not decode: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    static let exampleUniversityJSON = """
        {
          "id": "example",
          "name": "Example University",
          "creditSystem": "ECTS",
          "hoursPerCredit": 30,
          "defaultCredits": 6,
          "sittingsPerTerm": 2,
          "attempts": 3,
          "freeAttempt": false,
          "gradeImprovement": false,
          "gradeScale": "1.0–5.0; 4.0 passes",
          "withdrawRule": "Withdraw online up to seven days before the exam; a missed exam counts as failed.",
          "practiceExamSources": ["Past papers in the library"],
          "localTerms": {
            "admission": "Exam admission (coursework)",
            "exam": "Module exam",
            "second_date": "Resit: the term's second exam date",
            "registration": "Registration in the exam portal",
            "withdraw": "Withdrawal",
            "practice_exam": "Past papers",
            "exam_review": "Exam review"
          },
          "writtenExamMinutes": [60, 120],
          "defaultExamMinutes": 90,
          "terms": [
            {
              "name": "WS 2026/27",
              "examPeriods": [
                {"sitting": 1, "first": "2027-02-01", "last": "2027-02-20"},
                {"sitting": 2, "first": "2027-04-05", "last": "2027-04-16"}
              ],
              "registrations": [
                {
                  "sitting": 1, "first": "2026-12-14", "last": "2027-01-08", "system": "Exam portal",
                  "rule": "Registration for the first exam period: Mon 14 Dec 2026 – Fri 8 Jan 2027 in the exam portal."
                },
                {
                  "sitting": 2, "first": "2027-03-08", "last": "2027-03-14", "system": "Exam portal",
                  "rule": "Registration for the second exam period: Mon 8 – Sun 14 Mar 2027 in the exam portal."
                }
              ]
            }
          ]
        }
        """
}
