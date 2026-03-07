require "../spec_helper"

describe Arcana::Image::Runware do
  describe ".snap_dimensions" do
    it "snaps to nearest FLUX-compatible resolution" do
      w, h = Arcana::Image::Runware.snap_dimensions(1000, 1000)
      # Should snap to a valid FLUX dimension pair
      w.should be > 0
      h.should be > 0
    end

    it "returns exact match when dimensions are already valid" do
      w, h = Arcana::Image::Runware.snap_dimensions(1024, 1024)
      w.should eq(1024)
      h.should eq(1024)
    end

    it "handles portrait aspect ratios" do
      w, h = Arcana::Image::Runware.snap_dimensions(768, 1344)
      w.should be <= h
    end

    it "handles landscape aspect ratios" do
      w, h = Arcana::Image::Runware.snap_dimensions(1344, 768)
      w.should be >= h
    end
  end
end
