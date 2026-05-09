# from discord of far far west modding, by @Wr4Th_0f_D0g

Fmodel: tool for browsing the game files https://fmodel.app/

Retoc: tool for converting the "iostore" files FFW uses into an older format existing tools can work with (runs in command prompt) https://github.com/trumank/retoc/releases

UAssetGUI: tool for editing legacy assets (get the experimental version) https://github.com/atenfyr/UAssetGUI/releases

AES key: encryption key needed to open game files in fmodel 0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9

Mappings file: game-specific file needed in order to serialize certain data and actually read it in fmodel/uassetgui https://drive.google.com/file/d/1DI9AN-zsDBlGE5IvwkH2_EC7kZxnFLhO/view?usp=sharing

[insert guide here] (need someone to write all the steps in a readable format lol)

P.S. despite the title saying "basic" this will be a bit more involved than it would have been without the iostore format. Mostly just copy/pasting things between different windows though, so more tedious than difficult.


i suppose the palworld modding wiki could be useful aswell, it's also based on UE5 but a few versions behind far far west
https://pwmodding.wiki/docs/developers/3d-modeling/asset-swapping/Home



"retoc.exe --aes-key 0xDD5543BCC9C387A03DEADD72473D6A2EAF491AF88FC47365EE963F8AFE16B2D9 to-legacy -f Progress "C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Content\Paks" "C:\Users\(My User)\Downloads\FarFarWest_Modding\Legacy""
...
"remove -f Progress"


https://www.abbiedoobie.com/2023/10/13/modding-robocop-rogue-city-and-other-ue-5-games/ another good guide i found


task for docs: np. I hope people are able to get by with guides for other games. Although tbh I was really hoping someone would write something tailored to ffw to help me out lol. I hate writing