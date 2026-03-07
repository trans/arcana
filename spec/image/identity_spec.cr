require "../spec_helper"

describe Arcana::Image::Identity do
  describe ".seed_image" do
    it "creates a SeedImage identity with default strength" do
      id = Arcana::Image::Identity.seed_image("/ref.png")
      id.method.should eq(Arcana::Image::Identity::Method::SeedImage)
      id.reference_path.should eq("/ref.png")
      id.strength.should eq(0.95)
    end
  end

  describe ".ace_plus" do
    it "creates an AcePlus identity with task_type" do
      id = Arcana::Image::Identity.ace_plus("/ref.png", strength: 0.7, task_type: "subject")
      id.method.should eq(Arcana::Image::Identity::Method::AcePlus)
      id.strength.should eq(0.7)
      id.task_type.should eq("subject")
    end

    it "defaults to portrait task_type" do
      id = Arcana::Image::Identity.ace_plus("/ref.png")
      id.task_type.should eq("portrait")
      id.strength.should eq(0.65)
    end
  end

  describe ".pulid" do
    it "creates a PuLID identity" do
      id = Arcana::Image::Identity.pulid("/face.png")
      id.method.should eq(Arcana::Image::Identity::Method::PuLID)
      id.strength.should eq(0.65)
    end
  end

  describe ".ip_adapter" do
    it "creates an IPAdapter identity" do
      id = Arcana::Image::Identity.ip_adapter("/style.png", strength: 0.4)
      id.method.should eq(Arcana::Image::Identity::Method::IPAdapter)
      id.strength.should eq(0.4)
    end

    it "defaults strength to 0.5" do
      id = Arcana::Image::Identity.ip_adapter("/style.png")
      id.strength.should eq(0.5)
    end
  end
end
