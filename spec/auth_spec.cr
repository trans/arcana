require "./spec_helper"

# These specs require a real Postgres test database. If
# ARCANA_TEST_DATABASE_URL isn't set, the whole describe block
# is reported as pending (not failed) so CI without Postgres
# stays green.
#
# Set it up like:
#   createdb arcana_test
#   ARCANA_TEST_DATABASE_URL=postgres://localhost/arcana_test crystal spec
#
# Specs wipe and recreate the auth tables between test cases so
# ordering and isolation work cleanly.

if test_url = ENV["ARCANA_TEST_DATABASE_URL"]?
  describe Arcana::Auth do
    around_each do |example|
      ENV["ARCANA_DATABASE_URL"] = test_url
      Arcana::DB.close

      db = Arcana::DB.connection!
      # Drop and recreate from migrations on every test for full isolation.
      db.exec "DROP TABLE IF EXISTS api_keys CASCADE"
      db.exec "DROP TABLE IF EXISTS memberships CASCADE"
      db.exec "DROP TABLE IF EXISTS users CASCADE"
      db.exec "DROP TABLE IF EXISTS orgs CASCADE"
      db.exec "DROP TABLE IF EXISTS schema_migrations CASCADE"
      Arcana::DB::Migrate.run

      example.run
    ensure
      Arcana::DB.close
    end

    describe Arcana::Auth::Org do
      it "creates and looks up an org" do
        org = Arcana::Auth::Org.create(slug: "acme", name: "Acme Corp")
        org.id.should be > 0
        org.slug.should eq("acme")
        org.name.should eq("Acme Corp")
        org.is_system.should be_false

        Arcana::Auth::Org.find(org.id).not_nil!.slug.should eq("acme")
        Arcana::Auth::Org.find_by_slug("acme").not_nil!.id.should eq(org.id)
        Arcana::Auth::Org.find_by_slug("nope").should be_nil
      end

      it "rejects malformed slugs (CHECK constraint)" do
        expect_raises(Exception) do
          Arcana::Auth::Org.create(slug: "Bad Slug!", name: "x")
        end
      end

      it "lists orgs in id order" do
        Arcana::Auth::Org.create("first", "First")
        Arcana::Auth::Org.create("second", "Second")
        Arcana::Auth::Org.list.map(&.slug).should eq(["first", "second"])
      end

      it "marks system orgs distinctly" do
        Arcana::Auth::Org.create("system", "Platform", is_system: true).is_system.should be_true
        Arcana::Auth::Org.create("acme", "Acme").is_system.should be_false
      end
    end

    describe Arcana::Auth::User do
      it "creates and looks up by email" do
        user = Arcana::Auth::User.create(email: "alice@example.com", name: "Alice")
        user.email.should eq("alice@example.com")
        user.name.should eq("Alice")
        Arcana::Auth::User.find_by_email("alice@example.com").not_nil!.id.should eq(user.id)
      end

      it "treats email as unique" do
        Arcana::Auth::User.create("dup@example.com")
        expect_raises(Exception) { Arcana::Auth::User.create("dup@example.com") }
      end
    end

    describe Arcana::Auth::Membership do
      it "creates and lists by org and user" do
        org = Arcana::Auth::Org.create("acme", "Acme")
        alice = Arcana::Auth::User.create("alice@acme.example")
        bob = Arcana::Auth::User.create("bob@acme.example")
        Arcana::Auth::Membership.create(alice.id, org.id, Arcana::Auth::Role::Owner)
        Arcana::Auth::Membership.create(bob.id, org.id, Arcana::Auth::Role::Member)

        Arcana::Auth::Membership.for_org(org.id).size.should eq(2)
        Arcana::Auth::Membership.for_user(alice.id).first.role.should eq(Arcana::Auth::Role::Owner)
      end

      it "enforces user/org uniqueness" do
        org = Arcana::Auth::Org.create("acme", "Acme")
        alice = Arcana::Auth::User.create("alice@acme.example")
        Arcana::Auth::Membership.create(alice.id, org.id, Arcana::Auth::Role::Owner)
        expect_raises(Exception) do
          Arcana::Auth::Membership.create(alice.id, org.id, Arcana::Auth::Role::Member)
        end
      end
    end

    describe Arcana::Auth::ApiKey do
      it "creates a key, returns the secret exactly once, and verifies it" do
        org = Arcana::Auth::Org.create("acme", "Acme")
        key, secret = Arcana::Auth::ApiKey.create(name: "test", org_id: org.id)

        secret.should start_with("ak_")
        secret.size.should eq(35) # "ak_" + 32

        # Stored: prefix + hash, never the raw secret
        key.prefix.size.should eq(Arcana::Auth::ApiKey::PREFIX_LEN)
        key.hash.should_not eq(secret)
        key.hash.size.should eq(64) # SHA-256 hex

        # Verify with the secret returns the key
        verified = Arcana::Auth::ApiKey.verify(secret)
        verified.should_not be_nil
        verified.not_nil!.id.should eq(key.id)
      end

      it "rejects an unknown secret" do
        Arcana::Auth::ApiKey.verify("ak_doesnotexistxxxxxxxxxxxxxxxxxxxx").should be_nil
      end

      it "rejects a revoked key" do
        org = Arcana::Auth::Org.create("acme", "Acme")
        key, secret = Arcana::Auth::ApiKey.create(name: "test", org_id: org.id)
        key.revoke
        Arcana::Auth::ApiKey.verify(secret).should be_nil
      end

      it "supports a platform admin key (org_id NULL)" do
        key, _secret = Arcana::Auth::ApiKey.create(name: "platform")
        key.org_id.should be_nil
      end

      it "lists keys for an org" do
        org = Arcana::Auth::Org.create("acme", "Acme")
        Arcana::Auth::ApiKey.create(name: "one", org_id: org.id)
        Arcana::Auth::ApiKey.create(name: "two", org_id: org.id)
        Arcana::Auth::ApiKey.list_for_org(org.id).size.should eq(2)
      end

      it "tracks last_used_at via touch_used" do
        org = Arcana::Auth::Org.create("acme", "Acme")
        key, _secret = Arcana::Auth::ApiKey.create(name: "test", org_id: org.id)
        key.last_used_at.should be_nil
        key.touch_used
        Arcana::Auth::ApiKey.find_by_prefix(key.prefix).not_nil!.last_used_at.should_not be_nil
      end
    end

    describe Arcana::DB::Migrate do
      it "is idempotent — second run returns nothing applied" do
        # First run already happened in around_each via the reset.
        Arcana::DB::Migrate.run.should be_empty
      end
    end
  end
else
  pending "Arcana::Auth (set ARCANA_TEST_DATABASE_URL to run)"
end
