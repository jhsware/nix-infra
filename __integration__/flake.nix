{
  description = "A simple NixOS flake";

  inputs = {
    # NixOS official package source, using the specified branch here
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-[%%nixVersion%%]"; # Can we read this from configuration.nix?
    secrix.url = "github:Platonic-Systems/secrix"; # We should probably fork this
  };

  outputs = { self, nixpkgs, secrix, ... }@inputs: {
    # Please replace my-nixos with your hostname
    nixosConfigurations.[%%nodeName%%] = nixpkgs.lib.nixosSystem {
      system = "[%%hwArch%%]";
      modules = [
        # Allow commercially licensed packages
        { nixpkgs.config.allowUnfree = true; }
        # Import the previous configuration.nix we used,
        # so the old configuration file still takes effect
        ./configuration.nix
        {
          # Set all inputs parameters as special arguments for all submodules,
          # so you can directly use all dependencies in inputs in submodules
          _module.args = { inherit inputs; };
        }
      ];
    };
    apps.x86_64-linux.secrix = inputs.secrix.secrix self;
  };
}