{-# LANGUAGE MonadComprehensions, TupleSections, ImplicitParams, FlexibleContexts #-}
import Control.Applicative
import Control.Monad
import Control.Monad.State
import Control.Monad.Reader
import Data.List
import Data.Function
import Data.Array
import Data.Char
import Data.Maybe
import Data.Vect
import qualified Data.Map as M
import Control.Monad.Free
import System.Directory
import Graphics.FreeGame
import Paths_Monaris

type Coord = (Int, Int)
(a, b) #+# (c, d) = (a + c, b + d)
(a, b) #-# (c, d) = (a - c, b - d)
k *# (a, b) = (k * a, k * b)
(a, b) #/ k = (div a k, div b k)

data Color = Red | Yellow | Green | Cyan | Blue | Magenta | Orange deriving (Eq, Ord, Enum)

type Polyomino = [Coord]

polyominos = [([(0,0),(0,1),(0,2),(0,3)], Cyan)
             ,([(0,0),(0,1),(1,0),(1,1)], Yellow)
             ,([(0,0),(0,1),(0,2),(1,2)], Orange)
             ,([(0,0),(0,1),(0,2),(-1,2)], Blue)
             ,([(0,0),(0,1),(1,1),(1,2)], Green)
             ,([(0,0),(0,1),(-1,1),(-1,2)], Red)
             ,([(0,0),(-1,0),(1,0),(0,1)], Magenta)]

translate :: Coord -> Polyomino -> Polyomino
translate = map . (#+#)

type Field = Array Coord (Maybe Color)

data Spin = CCW | CW deriving (Show, Eq, Ord)

spin :: Spin -> Coord -> Polyomino -> Polyomino
spin CCW center = map $ (#/2) . (#+#center) . (\(x, y) -> (-y, x)) . (#-#center) . (2*#)
spin CW center  = map $ (#/2) . (#+#center) . (\(x, y) -> (y, -x)) . (#-#center) . (2*#)

centers :: Polyomino -> [Coord]
centers cs = cs' ++ [i | i@(c, r) <- map ((1,1)#+#) cs'
    , let c0 = minimum (map fst cs'), let c1 = maximum (map fst cs')
    , let r0 = minimum (map snd cs'), let r1 = maximum (map snd cs')
    , c0 < c && c < c1, r0 < r && r < r1] where cs' = map (2*#) cs

completeLines :: Field -> [Int]
completeLines field = [r | r <- [r0..r1], all isJust [field ! (c, r) | c <- [c0..c1]]] where
    ((c0, r0), (c1, r1)) = bounds field

deleteLine :: Field -> Int -> Field
deleteLine field n = array bnd [ a' | a@(ix@(c, r), _) <- assocs field
    , let a' | r == r0 = (ix, Nothing)
             | r <= n = (ix, field ! (c, r - 1))
             | otherwise = a] where
         bnd@((_, r0), _) = bounds field

putToField :: Color -> Field -> Polyomino -> Maybe Field
putToField color field omino = [field // map (,Just color) omino
    | all ((&&) <$> inRange (bounds field) <*> fmap isNothing (field !)) omino]

getPolyomino :: Game (Polyomino, Color)
getPolyomino = (polyominos!!) <$> randomness (0, length polyominos - 1)

spinStrategy :: Polyomino -> Field -> [Polyomino] -> Polyomino
spinStrategy original field = maximumBy (compare `on` ev) where
    g xs = fromIntegral (sum (map snd xs)) / fromIntegral (length xs)
    ev x = sum [fromEnum (g original <= g x)
        + sum [1 | c <- neighbors, not (inRange (bounds field) c) || isJust (field ! c)] ^ 2
        | r <- nub $ map snd x]
        where neighbors = nub $ (#+#) <$> x <*> [(0, 1), (0, -1), (1, 0), (1, 1)]

place :: (?picBlocks :: M.Map (Color, Int) Picture, ?blockSize :: Float, ?picBlockBackground :: Picture)
    => Polyomino -> Color -> Field -> Int -> Game (Maybe Field)
place polyomino color field period = do
    if or [isJust $ field ! (c, r) | (c, r) <- range ((c0, r0), (c1, -1))] then return Nothing 
        else run 1 (Left 0) (False, False, False, False, False, False)
            `evalStateT` translate (5, -1 - maximum (map snd polyomino)) polyomino
    where
    ((c0, r0), (c1, r1)) = bounds field
    putF = putToField color field
    run t param ks = do
        [l',r',u',d',z',x'] <- lift $ mapM askInput [KeyLeft, KeyRight, KeyUp, KeyDown, KeyChar 'Z', KeyChar 'X']
        when (t `mod` period == 0) $ void $ move (0, 1)

        omino <- get
        
        drawPicture $ renderField field
        param' <- flip runReaderT (ks, (l',r',u',d',z',x'))
            $ if isNothing $ putF $ translate (0, 1) omino
                then fmap Right <$> handleLanding (either (const (60, 120)) id param)
                else fmap Left <$> handleNotLanding (either id (const 0) param)

        drawPicture $ renderPolyomino 0 omino color        
        case param' of
            Just p -> tick >> run (succ t) p (l',r',u',d',z',x')
            Nothing -> return (putF omino)
    
    handleCommon = do
        ((l,r,u,d,z,x),(l',r',u',d',z',x')) <- ask
        a <- case (not l && l', not r && r') of
            (True, False) -> move (-1, 0)
            (False, True) -> move (1, 0)
            _ -> return False
        b <- case (not z && z', not x && x') of
            (True, False) -> sp CCW
            (False, True) -> sp CW
            _ -> return False
        return $ a || b
    
    handleLanding (0, _) = return Nothing
    handleLanding (play, playBound) = do
        ((l,r,u,d,z,x),(l',r',u',d',z',x')) <- ask
        omino <- get
        drawPicture $ renderPolyomino 7 omino color
        if not u && u' || not d && d' then return Nothing else do
            f <- handleCommon
            return $ Just $ if f then (playBound / 2, playBound - 10) else (play - 1, playBound)
    
    handleNotLanding t = do
        handleCommon
        ((l,r,u,d,z,x),(l',r',u',d',z',x')) <- ask
        omino <- get
        drawPicture $ renderPolyomino 6 (destination omino) color
        when (not u && u') $ modify destination
        if d'
            then do
                when (t `mod` 5 == 0) $ void $ move (0, 1)
                return (Just (succ t))
            else return (Just 0)

    move dir = do omino <- translate dir <$> get
                  if isJust $ putF omino
                      then put omino >> return True
                      else return False
    
    sp dir = do omino <- get
                case filter (isJust . putF) $ map (flip (spin dir) omino) $ centers omino of
                     [] -> return False
                     xs -> put (spinStrategy omino field xs) >> return True

    destination omino
        | isNothing $ putF omino' = omino
        | otherwise = destination omino'
        where omino' = translate (0, 1) omino

eliminate :: (?picBlocks :: M.Map (Color, Int) Picture, ?blockSize :: Float, ?picBlockBackground :: Picture)
    => Field -> Game (Field, Int)
eliminate field = do
    when (not.null $ rows) $ forM_ [0..5] $ \i -> replicateM_ 2 $ draw i >> tick
    return (foldl deleteLine field rows, length rows)
    where
        rows = completeLines field
        draw n = drawPicture $ flip renderFieldBy field
                $ \(_, r) color -> ?picBlocks M.! (color, if r `elem` rows then n else 0)

gameOver :: (?picBlocks :: M.Map (Color, Int) Picture, ?blockSize :: Float) => Field -> Game ()
gameOver field = do
    let pics = [Translate pos (?picBlocks M.! (p, 0)) | (ix@(c, r), color) <- assocs field
            , let pos = ?blockSize *& Vec2 (fromIntegral c) (fromIntegral r)
            , p <- maybeToList color]
    objs <- forM pics $ \pic -> do
        dx <- randomness (-1,1)
        return (zero, Vec2 dx (-3), pic)
    run 120 objs
    where
        update (pos, v, pic) = drawPicture (Translate pos pic)
            >> return (pos &+ v, v &+ Vec2 0 0.2, pic)
        run 0 _ = return ()
        run n objs = do
            objs' <- mapM update objs
            tick
            run (n - 1) objs'

gameMain :: (?blockSize :: Float, ?picBlocks :: M.Map (Color, Int) Picture
    , ?picCharWidth :: Float , ?picChars :: M.Map Char Picture
    , ?picBackground :: Picture, ?picBlockBackground :: Picture
    , ?highScore :: Int)
    => Field -> Int -> Float -> (Polyomino, Color) -> (Polyomino, Color) -> Game Int
gameMain field total line (omino, color) next = do
    r <- embed $ place omino color field (floor $ 60 * 2**(-line/50))
    case r of
        Nothing -> embed (gameOver field) >> return total
        Just field' -> do
            (field'', n) <- embed $ eliminate field'
            next' <- getPolyomino
            gameMain field'' (total + n ^ 2) (line + fromIntegral n) next next'
    where
        embed (Pure a) = return a
        embed m = do
            let drawTo x y = drawPicture . Translate (Vec2 x y)
            drawTo 320 240 ?picBackground
            cont <- hoistFree (transPicture $ Translate (Vec2 24 24)) $ do
                drawPicture $ renderFieldBackground field
                untickGame m
            drawTo 480 133 $ renderString $ show total
            drawTo 480 166 $ renderString $ show ?highScore
            drawTo 500 220 $ uncurry (renderPolyomino 0) next
            tick
            embed cont

gameTitle :: (?picCharWidth :: Float, ?picChars :: M.Map Char Picture, ?picTitle :: Picture, ?highScore :: Int)
    => Game ()
gameTitle = do
    z <- askInput (KeyChar 'Z')
    drawPicture $ Translate (Vec2 320 240) ?picTitle
    drawPicture $ Translate (Vec2 490 182) $ renderString (show ?highScore)
    tick
    when (not z) gameTitle
    return ()

renderFieldBackground :: (?picBlockBackground :: Picture, ?blockSize :: Float) => Field -> Picture
renderFieldBackground field = Pictures $ [Translate pos ?picBlockBackground
    | (c, r) <- indices field, r >= 0
    , let pos = ?blockSize *& Vec2 (fromIntegral c) (fromIntegral r)]

renderField :: (?picBlocks :: M.Map (Color, Int) Picture, ?blockSize :: Float, ?picBlockBackground :: Picture)
    => Field -> Picture
renderField = renderFieldBy $ \_ color -> ?picBlocks M.! (color, 0)

renderFieldBy :: (?blockSize :: Float)
    => (Coord -> Color -> Picture) -> Field -> Picture
renderFieldBy f field = Pictures $ [Translate pos pic
    | (ix@(c, r), color) <- assocs field
    , r >= 0, let pos = ?blockSize *& Vec2 (fromIntegral c) (fromIntegral r)
    , pic <- maybeToList (f ix <$> color)]

renderPolyomino :: (?picBlocks :: M.Map (Color, Int) Picture, ?blockSize :: Float)
    => Int -> Polyomino -> Color -> Picture
renderPolyomino i omino color = Pictures [Translate pos (?picBlocks M.! (color, i))
    | (c, r) <- omino, r >= 0, let pos = ?blockSize *& Vec2 (fromIntegral c) (fromIntegral r)]

renderString :: (?picCharWidth :: Float, ?picChars :: M.Map Char Picture) => String -> Picture
renderString str = Pictures [Translate (Vec2 (?picCharWidth * i) 0) $ ?picChars M.! ch
    | (i, ch) <- zip [0..] str]

main :: IO ()
main = void $ runGame (defaultGameParam {windowTitle="Monaris"}) $ do

    let colors = enumFrom Red
        initialField = listArray ((0,-4), (9,18)) (repeat Nothing)
        load path = embedIO $ getDataFileName path >>= loadBitmapFromFile
    imgChars <- load "images/numbers.png"
    picChars' <- liftM M.fromAscList $ forM [0..9]
        $ \n -> (,) (intToDigit n) <$> loadPicture (cropBitmap imgChars (24, 32) (n * 24, 0))

    imgBlocks <- load "images/Block.png"
    picBlocks' <- liftM M.fromAscList $ forM ((,) <$> zip [0..] colors <*> [0..7])
        $ \((i, color), j) -> (,) (color, j) <$> loadPicture (cropBitmap imgBlocks (48, 48) (i * 48, j * 48))

    imgBackground <- load "images/background.png" >>= loadPicture
    imgBlockBackground <- load "images/block-background.png" >>= loadPicture
    
    imgTitle <- load "images/title.png" >>= loadPicture
    highscorePath <- embedIO $ (++"/.monaris_highscore") <$> getHomeDirectory

    let ?picCharWidth = 18
        ?picChars = picChars'
        ?blockSize = 24
        ?picBlocks = picBlocks'
        ?picBackground = imgBackground
        ?picBlockBackground = imgBlockBackground
        ?picTitle = imgTitle

    let loop h = do
            let ?highScore = h
            _ <- gameTitle
            score <- join $ gameMain initialField 0 0 <$> getPolyomino <*> getPolyomino
            when (?highScore < score) $ embedIO $ writeFile highscorePath (show score)
            loop (max score ?highScore)

    f <- embedIO $ doesFileExist highscorePath
    score <- if f then embedIO $ read <$> readFile highscorePath else return 0
    loop score
