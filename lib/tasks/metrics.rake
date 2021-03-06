require 'date'
require 'time'

class Moment
  def self.to_a
    ["Year", "Month", "ISO Year", "ISO Week"]
  end

  attr_reader :ts
  def initialize(s)
    @ts = DateTime.strptime(s, "%Y-%m-%d %H:%M:%S")
  end

  def cohort
    "%d:%02d" % [ts.cwyear, ts.cweek]
  end

  def to_a
    [ts.year, ts.month, ts.cwyear, ts.cweek]
  end

  def to_s
    ts.strftime("%Y-%m-%d")
  end
end

class Metric
  def self.report(sql, headers, fn)
    require 'active_record'
    require 'db/connection'
    DB::Connection.establish

    rows = ActiveRecord::Base.connection.execute(sql)
    puts headers.join(",")
    rows.each do |row|
      puts fn.call(row)
    end
  end
end

def days(first, last)
  return 0 if last.nil?
  (DateTime.parse(last)-DateTime.parse(first)).to_i + 1
end

def ttf(signup, submit)
  return "(4) never" if submit.nil?

  diff = Time.parse(submit)-Time.parse(signup)

  return '(1) day' if diff < 24*60*60
  return '(2) week' if diff < 24*60*60*7
  '(3) more'
end

namespace :metrics do
  namespace :events do
    desc "extract signup events"
    task :signups do
      sql = <<-SQL
        SELECT id, created_at FROM users ORDER BY created_at ASC
      SQL
      fn = lambda { |row|
        at = Moment.new(row['created_at'])
        ([ row['id'], at.to_s] + at.to_a).join(",")
      }
      Metric.report(sql, ["User ID", "Signed Up On"]+Moment.to_a, fn)
    end

    desc "extract comment events"
    task :comments do
      sql = <<-SQL
        SELECT id, user_id, created_at FROM comments ORDER BY created_at ASC
      SQL
      fn = lambda { |row|
        at = Moment.new(row['created_at'])
        ([ row['id'], row['user_id'], at.to_s] + at.to_a).join(",")
      }
      Metric.report(sql, ["Comment ID", "User ID", "Submitted On"]+Moment.to_a, fn)
    end

    desc "extract iteration events"
    task :iterations do
      sql = "SELECT id, user_id, created_at FROM submissions ORDER BY created_at ASC"
      fn = lambda { |row|
        at = Moment.new(row['created_at'])
        ([ row['id'], row['user_id'], at.to_s] + at.to_a).join(",")
      }
      Metric.report(sql, ["Comment ID", "User ID", "Submitted On"]+Moment.to_a, fn)
    end
  end

  desc "feedback"
  task :feedback do
    sql = <<-SQL
      SELECT
        user_exercise_id AS id,
        MIN(created_at) AS created_at,
        (CASE WHEN SUM(nit_count) > 0 THEN 1 ELSE 0 END) AS received_feedback
      FROM submissions
      WHERE slug<>'hello-world'
      GROUP BY user_exercise_id
    SQL

    fn = lambda { |row|
      at = Moment.new(row['created_at'])
      ([ row['id'], at.to_s, row['received_feedback']] + at.to_a).join(",")
    }
    Metric.report(sql, ["Solution ID", "Started On", "Received Feedback"]+Moment.to_a, fn)
  end

  desc "lifetime numbers"
  task :lifetime do
    sql = <<-SQL
      SELECT
        u.id,
        s.tally AS iterations,
        COALESCE(cg.tally, 0) AS comments_given,
        COALESCE(cr.tally, 0) AS comments_received,
        COALESCE(x.exercises, 0) AS exercises,
        COALESCE(x.languages, 0) AS languages,
        s.first_iteration_at,
        s.latest_iteration_at
      FROM users u
      INNER JOIN (
        SELECT
          user_id,
          COUNT(id) AS tally,
          MIN(created_at) AS first_iteration_at,
          MAX(created_at) AS latest_iteration_at
        FROM submissions
        GROUP BY user_id
      ) AS s
      ON u.id=s.user_id
      LEFT JOIN (
        SELECT user_id, COUNT(id) AS tally
        FROM comments
        GROUP BY user_id
      ) AS cg
      ON u.id=cg.user_id
      LEFT JOIN (
        SELECT
          submissions.user_id,
          COUNT(comments.id) AS tally
        FROM submissions
        INNER JOIN comments
        ON submissions.id=comments.submission_id
        GROUP BY submissions.user_id
      ) AS cr
      ON cr.user_id=u.id
      LEFT JOIN (
        SELECT
          user_id,
          COUNT(id) AS exercises,
          COUNT(DISTINCT(language)) AS languages
        FROM user_exercises
        WHERE iteration_count>0
        GROUP BY user_id
      ) AS x
      ON u.id=x.user_id
    SQL
    fn = lambda { |row|
      [
        row['id'],
        row['comments_given'],
        row['comments_received'],
        row['iterations'],
        row['exercises'],
        row['languages'],
        days(row['first_iteration_at'], row['latest_iteration_at']),
      ].join(",")
    }
    headers = ["User ID", "Comments Given", "Comments Received", "Iterations", "Exercises", "Languages", "Active For (days)"]
    Metric.report(sql, headers, fn)
  end

  desc "extract funnel metrics"
  task :funnel do
    sql = <<-SQL
      SELECT
        u.id,
        u.created_at AS signed_up_at,
        COALESCE(s.yes, 0) AS has_submitted,
        COALESCE(d.yes, 0) AS has_discussed,
        COALESCE(r.yes, 0) AS has_reviewed,
        COALESCE(f.yes, 0) AS has_received_feedback,
        s.first_submission_at
      FROM users u
      LEFT JOIN (
        SELECT user_id, MIN(created_at) AS first_submission_at, 1 AS yes
        FROM submissions
        GROUP BY user_id
      ) AS s
      ON s.user_id=u.id
      LEFT JOIN (
        SELECT DISTINCT(ds.user_id), 1 AS yes
        FROM submissions ds
        INNER JOIN comments dc
        ON ds.id=dc.submission_id
        WHERE ds.user_id=dc.user_id
      ) AS d
      ON d.user_id=u.id
      LEFT JOIN (
        SELECT DISTINCT(rc.user_id), 1 AS yes
        FROM submissions rs
        INNER JOIN comments rc
        ON rs.id=rc.submission_id
      ) AS r
      ON r.user_id=u.id
      LEFT JOIN (
        SELECT DISTINCT(fs.user_id), 1 AS yes
        FROM submissions fs
        INNER JOIN comments fc
        ON fs.id=fc.submission_id
      ) AS f
      ON f.user_id=u.id
    SQL
    fn = lambda { |row|
      [
        row['id'],
        Moment.new(row['signed_up_at']).cohort,
        row['has_submitted'],
        row['has_discussed'],
        row['has_reviewed'],
        row['has_received_feedback'],
        ttf(row['signed_up_at'], row['first_submission_at']),
      ].join(",")
    }
    Metric.report(sql, ["User ID", "Cohort", "Submitted", "Discussed", "Reviewed", "Got Feedback", "Time to First Submission"], fn)
  end
end
